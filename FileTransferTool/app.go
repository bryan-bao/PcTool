package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"filetransfer/internal/discovery"
	"filetransfer/internal/netinfo"
	"filetransfer/internal/qrcode"
	"filetransfer/internal/sender"
	"filetransfer/internal/server"
	"filetransfer/internal/transfer"

	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// safeMultiWriter 逐个写入并忽略各自的错误,且总报告写入成功。
// 必须这样做:GUI 程序没有有效的 os.Stdout,标准 io.MultiWriter 一旦写 stdout 出错
// 就会短路、不再写后面的日志文件,导致日志文件永远是空的。
type safeMultiWriter struct{ ws []io.Writer }

func (s safeMultiWriter) Write(p []byte) (int, error) {
	for _, w := range s.ws {
		_, _ = w.Write(p)
	}
	return len(p), nil
}

// setupLogging 把日志同时输出到控制台和保存目录下的 filetransfer.log,
// 这样即使是双击运行的打包 exe(没有控制台)也能在日志文件里看到发生了什么。
func setupLogging(dir string) {
	var writers []io.Writer
	logPath := filepath.Join(dir, "filetransfer.log")
	if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
		writers = append(writers, f)
	}
	writers = append(writers, os.Stdout)
	log.SetOutput(safeMultiWriter{writers})
	log.SetFlags(log.LstdFlags)
}

// App 是 Wails 绑定门面,桌面前端通过它调用后端。
type App struct {
	ctx     context.Context
	mgr     *transfer.Manager
	srv     *server.Server
	pub     *discovery.Publisher
	rsp     *discovery.Responder // UDP 广播发现应答器
	ip      string
	port    int
	saveDir string
	shareID string // 「发文件链接」的分享会话 id(首次添加时创建,全程只用这一个)
}

// NewApp 构造。
func NewApp() *App {
	return &App{mgr: transfer.NewManager(0)}
}

func randToken() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// startup 在 Wails 启动时调用:起服务、采样、mDNS,并把任务变更转发给前端事件。
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	if ip, err := netinfo.LocalIPv4(); err == nil {
		a.ip = ip.String()
	}
	a.port = netinfo.PreferredOrFreePort(52718)
	host, _ := os.Hostname()

	a.saveDir = defaultSaveDir()
	_ = os.MkdirAll(a.saveDir, 0o755)
	setupLogging(a.saveDir)

	a.srv = server.New(a.mgr, host, randToken(), a.saveDir)
	// 任务变更 → 推给桌面前端
	a.mgr.OnChange(func(t *transfer.Task) {
		wailsruntime.EventsEmit(a.ctx, "task", t)
	})
	go a.srv.Start(a.port)
	go transfer.NewSpeedSampler(a.mgr, time.Second).Run(ctx)
	if pub, err := discovery.Publish(host, a.port); err == nil {
		a.pub = pub
	} else {
		log.Printf("[发现] mDNS 注册失败: %v", err)
	}
	if rsp, err := discovery.StartResponder(host, a.port); err == nil {
		a.rsp = rsp
	} else {
		log.Printf("[发现] UDP 应答器启动失败(可能已有实例占用): %v", err)
	}

	log.Printf("======== 局域网文件传输 启动 ========")
	log.Printf("本机名: %s", host)
	log.Printf("局域网 IP: %s  监听端口: %d", a.ip, a.port)
	log.Printf("手机访问地址: %s", a.srv.MobileURL(a.ip, a.port))
	log.Printf("接收文件保存到: %s", a.saveDir)
}

// shutdown 在 Wails 退出时调用,注销 mDNS 与 UDP 应答器。
func (a *App) shutdown(ctx context.Context) {
	if a.pub != nil {
		a.pub.Shutdown()
	}
	if a.rsp != nil {
		a.rsp.Close()
	}
}

// defaultSaveDir 默认把接收文件放在 exe 同目录的 received 文件夹:
// 跟着 exe 走、不进 C 盘系统区、换台电脑也通用。
func defaultSaveDir() string {
	if exe, err := os.Executable(); err == nil {
		return filepath.Join(filepath.Dir(exe), "received")
	}
	return "received"
}

// ---- 下面是给前端调用的方法 ----

// MobileQR 返回手机扫码用的二维码 dataURL。
func (a *App) MobileQR() (string, error) {
	return qrcode.DataURL(a.srv.MobileURL(a.ip, a.port), 256)
}

// MobileURL 返回手机访问地址文本(便于手动输入)。
func (a *App) MobileURL() string { return a.srv.MobileURL(a.ip, a.port) }

// CopyURL 把手机访问地址复制到系统剪贴板,方便发给别人用浏览器打开。
func (a *App) CopyURL() {
	_ = wailsruntime.ClipboardSetText(a.ctx, a.srv.MobileURL(a.ip, a.port))
}

// LocalAddr 返回本机地址 ip:port(告诉别人来连,远程时填 Tailscale 地址)。
func (a *App) LocalAddr() string { return fmt.Sprintf("%s:%d", a.ip, a.port) }

// InstallTailscale 用 winget 一键安装 Tailscale,返回结果文字给界面显示。
// 安装会触发系统的管理员权限确认(UAC),用户点“是”即可。
func (a *App) InstallTailscale() string {
	if _, err := exec.LookPath("winget"); err != nil {
		return "这台电脑没有 winget,无法一键安装。请去 tailscale.com/download 手动下载安装。"
	}
	log.Printf("[Tailscale] 开始用 winget 安装…")
	cmd := exec.Command("winget", "install", "--id", "Tailscale.Tailscale", "-e",
		"--accept-source-agreements", "--accept-package-agreements")
	err := cmd.Run()
	if err != nil {
		log.Printf("[Tailscale] winget 返回: %v", err)
		return "安装已结束。若提示“已安装”说明之前装过了。请点右下角任务栏托盘的 Tailscale 图标登录;若仍没装上,可去 tailscale.com/download 手动安装。"
	}
	log.Printf("[Tailscale] 安装完成")
	return "✅ 安装完成!请点右下角任务栏托盘的 Tailscale 图标,登录账号(两台电脑用同一个账号)。"
}

// SaveDir 返回接收文件保存目录。
func (a *App) SaveDir() string { return a.srv.SaveDir() }

// PickSaveDir 弹出目录选择框,把接收文件保存目录改到用户选的位置,返回最终目录。
func (a *App) PickSaveDir() string {
	dir, err := wailsruntime.OpenDirectoryDialog(a.ctx, wailsruntime.OpenDialogOptions{
		Title: "选择接收文件的保存位置",
	})
	if err != nil || dir == "" {
		return a.srv.SaveDir()
	}
	_ = os.MkdirAll(dir, 0o755)
	a.srv.SetSaveDir(dir)
	a.saveDir = dir
	log.Printf("[设置] 接收保存目录改为: %s", dir)
	return dir
}

// Tasks 返回当前所有任务。
func (a *App) Tasks() []*transfer.Task { return a.mgr.List() }

// SetGlobalLimit 设置全局限速(字节/秒,0=不限)。
func (a *App) SetGlobalLimit(bps int) { a.mgr.SetGlobalLimit(bps) }

// SetTaskLimit 设置某任务限速。
func (a *App) SetTaskLimit(id string, bps int) { a.mgr.SetTaskLimit(id, bps) }

// Accept 接受接收任务。
func (a *App) Accept(id string) { a.mgr.SetStatus(id, transfer.StatusTransferring, "") }

// Reject 拒绝接收任务。
func (a *App) Reject(id string) { a.mgr.SetStatus(id, transfer.StatusRejected, "") }

// DiscoverPeers 发现局域网内其他电脑(约 2.5s)。
// mDNS 和 UDP 广播两路并行(mDNS 在 Windows 多网卡下经常抽风,UDP 兜底),
// 结果合并去重,并把本机自己排除掉。
func (a *App) DiscoverPeers() ([]discovery.Peer, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 2500*time.Millisecond)
	defer cancel()

	var wg sync.WaitGroup
	var mdnsPeers, udpPeers []discovery.Peer
	wg.Add(2)
	go func() { defer wg.Done(); mdnsPeers, _ = discovery.Discover(ctx) }()
	go func() { defer wg.Done(); udpPeers, _ = discovery.DiscoverUDP(2 * time.Second) }()
	wg.Wait()

	self := netinfo.LocalIPv4Set()
	seen := make(map[string]bool)
	out := []discovery.Peer{}
	for _, p := range append(udpPeers, mdnsPeers...) {
		if p.Host == "" || self[p.Host] {
			continue // 没有地址的、本机自己的,都不要
		}
		key := fmt.Sprintf("%s:%d", p.Host, p.Port)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, p)
	}
	log.Printf("[发现] 扫描完成: UDP %d 台, mDNS %d 台, 去重排己后 %d 台", len(udpPeers), len(mdnsPeers), len(out))
	return out, nil
}

// PickFiles 弹出系统文件选择框,返回选中的本地文件路径(多选)。
func (a *App) PickFiles() ([]string, error) {
	return wailsruntime.OpenMultipleFilesDialog(a.ctx, wailsruntime.OpenDialogOptions{
		Title: "选择要发送的文件",
	})
}

// PickFolder 弹出文件夹选择框,返回选中的文件夹路径(取消则为空)。
func (a *App) PickFolder() (string, error) {
	return wailsruntime.OpenDirectoryDialog(a.ctx, wailsruntime.OpenDialogOptions{
		Title: "选择要发送的文件夹",
	})
}

// OpenSaveDir 在资源管理器里打开接收文件保存目录。
func (a *App) OpenSaveDir() {
	_ = exec.Command("explorer", a.srv.SaveDir()).Start()
}

// ShareState 是「发文件链接」区的完整状态:一个固定链接 + 当前分享的条目列表。
// 不管加多少次文件/文件夹,都进同一个分享、共用同一个链接。
type ShareState struct {
	URL     string              `json:"url"`
	TSURL   string              `json:"tsUrl"` // Tailscale 远程链接(没装则为空)
	Entries []server.ShareEntry `json:"entries"`
}

// shareStateNow 取当前分享状态(链接 + 条目列表)。
func (a *App) shareStateNow() *ShareState {
	st := &ShareState{Entries: []server.ShareEntry{}}
	if a.shareID == "" {
		return st
	}
	st.Entries = a.srv.ShareEntries(a.shareID)
	st.URL = fmt.Sprintf("http://%s:%d/s/%s", a.ip, a.port, a.shareID)
	if ip, err := netinfo.TailscaleIPv4(); err == nil {
		st.TSURL = fmt.Sprintf("http://%s:%d/s/%s", ip.String(), a.port, a.shareID)
	}
	return st
}

// ShareState 返回当前分享状态(界面初始化/刷新用)。
func (a *App) ShareState() *ShareState { return a.shareStateNow() }

// ShareAddFiles 弹文件多选框,把文件加进分享(取消选择则原样返回当前状态)。
func (a *App) ShareAddFiles() (*ShareState, error) {
	paths, err := wailsruntime.OpenMultipleFilesDialog(a.ctx, wailsruntime.OpenDialogOptions{
		Title: "选择要分享的文件",
	})
	if err != nil || len(paths) == 0 {
		return a.shareStateNow(), err
	}
	return a.shareAdd(paths)
}

// ShareAddFolder 弹文件夹选择框,把整个文件夹按一个条目加进分享(对方可打包下载)。
func (a *App) ShareAddFolder() (*ShareState, error) {
	dir, err := wailsruntime.OpenDirectoryDialog(a.ctx, wailsruntime.OpenDialogOptions{
		Title: "选择要分享的文件夹",
	})
	if err != nil || dir == "" {
		return a.shareStateNow(), err
	}
	return a.shareAdd([]string{dir})
}

func (a *App) shareAdd(paths []string) (*ShareState, error) {
	id, err := a.srv.ShareAdd(a.shareID, paths)
	if err != nil {
		return a.shareStateNow(), err
	}
	a.shareID = id
	st := a.shareStateNow()
	log.Printf("[分享] 当前 %d 个条目 -> %s", len(st.Entries), st.URL)
	return st, nil
}

// ShareRemove 把某个条目移出分享,返回最新状态。
func (a *App) ShareRemove(entryID string) *ShareState {
	if a.shareID != "" {
		a.srv.ShareRemove(a.shareID, entryID)
	}
	return a.shareStateNow()
}

// CopyText 把任意文本复制到系统剪贴板(前端复制链接用)。
func (a *App) CopyText(text string) {
	_ = wailsruntime.ClipboardSetText(a.ctx, text)
}

// SendToPeer 把若干本地文件/文件夹发送到对端电脑(host:port,通常来自局域网扫描结果)。
// 文件夹会展开成内部所有文件(含子目录),按相对路径发送,对端自动重建目录结构。
// 每个文件一个发送任务,后台并发进行,进度通过任务事件推给界面。
func (a *App) SendToPeer(host string, port int, paths []string) {
	base := fmt.Sprintf("http://%s:%d", host, port)
	myName, _ := os.Hostname()
	type item struct{ path, rel string }
	var files []item
	for _, p := range paths {
		fi, err := os.Stat(p)
		if err != nil {
			continue // 读不到的跳过
		}
		if !fi.IsDir() {
			files = append(files, item{p, filepath.Base(p)})
			continue
		}
		root, baseName := p, filepath.Base(p)
		_ = filepath.WalkDir(root, func(fp string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			rel, err := filepath.Rel(root, fp)
			if err != nil {
				return nil
			}
			files = append(files, item{fp, filepath.ToSlash(filepath.Join(baseName, rel))})
			return nil
		})
	}
	for _, it := range files {
		id := randToken()
		// Name 用相对路径,两边任务列表都能看出文件在文件夹里的位置
		tk := a.mgr.Add(&transfer.Task{
			ID: id, Name: it.rel, RelPath: it.rel,
			Direction: transfer.DirSend, Status: transfer.StatusTransferring, Peer: host,
		})
		log.Printf("[发送] 开始发送 %s 到 %s", it.rel, base)
		go func(path, taskID string, task *transfer.Task) {
			err := sender.SendFile(base, myName, task, path,
				a.mgr.GlobalLimiter(), a.mgr.TaskLimiter(taskID), func() { a.mgr.Touch(taskID) })
			if err != nil {
				log.Printf("[发送] 失败 %s: %v", task.Name, err)
				a.mgr.SetStatus(taskID, transfer.StatusFailed, err.Error())
			} else {
				log.Printf("[发送] 完成 %s", task.Name)
				a.mgr.SetStatus(taskID, transfer.StatusDone, "")
			}
		}(it.path, id, tk)
	}
}
