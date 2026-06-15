# 局域网文件传输工具 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Go + Wails 做一个编译成单 exe、双击出窗口的局域网文件传输工具,支持电脑↔电脑、电脑↔手机互传,带限速(档位/上限/每任务)、实时速度、断点续传、整文件夹传、接收方确认。

**Architecture:** 一个 Wails 应用 = Go 后端 + 网页前端。Go 后端开一个局域网 HTTP/WebSocket 服务(给手机浏览器和其他电脑连),用 mDNS 自动发现同网段的其他实例,用令牌桶做两级限速(全局闸 + 每任务闸),传输按字节偏移记录以支持断点续传。桌面窗口 UI 由 Wails 的 webview 承载;手机端 UI 是一套用 `go:embed` 打进二进制的响应式 H5 页面,由 HTTP 服务提供。两套 UI 都通过同一组 HTTP/WS API 工作。

**Tech Stack:** Go 1.22+、Wails v2、`golang.org/x/time/rate`(限速)、`github.com/grandcat/zeroconf`(mDNS)、`github.com/skip2/go-qrcode`(二维码)、`nhooyr.io/websocket` 或标准 `gorilla/websocket`(WS 推送)、前端用 Wails vanilla 模板(原生 JS + CSS)。

---

## 项目文件结构

```
FileTransferTool/
├── go.mod
├── wails.json
├── main.go                       # Wails 入口,装配各模块
├── app.go                        # 绑定给桌面前端调用的 App 方法
├── internal/
│   ├── netinfo/
│   │   ├── netinfo.go            # 取本机局域网 IPv4、挑可用端口
│   │   └── netinfo_test.go
│   ├── ratelimit/
│   │   ├── limiter.go           # 两级令牌桶限速 + LimitedReader/Writer
│   │   └── limiter_test.go
│   ├── transfer/
│   │   ├── task.go              # 传输任务模型与状态机
│   │   ├── task_test.go
│   │   ├── manager.go           # 任务管理器(增删查、进度统计、限速联动)
│   │   ├── manager_test.go
│   │   ├── resume.go            # 断点续传偏移计算
│   │   └── resume_test.go
│   ├── qrcode/
│   │   ├── qrcode.go            # 生成二维码 PNG 的 base64 dataURL
│   │   └── qrcode_test.go
│   ├── discovery/
│   │   ├── mdns.go              # mDNS 发布本机 + 发现同网段实例
│   │   └── mdns_test.go
│   └── server/
│       ├── server.go           # HTTP/WS 服务装配、生命周期
│       ├── handlers.go         # /api/offer /api/upload /api/download 等
│       ├── handlers_test.go
│       ├── ws.go               # WebSocket hub:向前端/手机推送进度与确认请求
│       └── web/
│           ├── mobile.html     # 手机端响应式页面(go:embed)
│           ├── mobile.js
│           └── mobile.css
├── frontend/                    # Wails 桌面窗口 UI(vanilla 模板生成)
│   ├── index.html
│   ├── src/
│   │   ├── main.js
│   │   ├── app.css
│   │   └── api.js              # 封装对 Go 绑定方法 + WS 的调用
│   └── wailsjs/                # Wails 自动生成的绑定(勿手改)
└── docs/superpowers/...
```

每个文件单一职责;`internal/` 下纯 Go 逻辑可独立单测,`server`/`discovery`/Wails 装配走集成+手动验证。

---

## 阶段 0:环境与项目骨架

### Task 0.1:安装 Go 到 D 盘

**Files:** 无(系统环境)

- [ ] **Step 1: 下载并解压 Go 到 D 盘**

按用户落盘规则,Go 不进 C 盘。安装到 `D:\dev\go`(GOROOT),工作缓存到 `D:\dev\gopath`。

Run(PowerShell):
```powershell
$ver = "go1.22.5"
$zip = "$env:TEMP\$ver.windows-amd64.zip"
Invoke-WebRequest "https://go.dev/dl/$ver.windows-amd64.zip" -OutFile $zip
New-Item -ItemType Directory -Force "D:\dev" | Out-Null
Expand-Archive $zip -DestinationPath "D:\dev" -Force   # 解出 D:\dev\go
```
Expected: `D:\dev\go\bin\go.exe` 存在。

- [ ] **Step 2: 配置环境变量(指向 D 盘,持久化到用户级)**

Run(PowerShell):
```powershell
[Environment]::SetEnvironmentVariable("GOROOT", "D:\dev\go", "User")
[Environment]::SetEnvironmentVariable("GOPATH", "D:\dev\gopath", "User")
[Environment]::SetEnvironmentVariable("GOMODCACHE", "D:\dev\gopath\pkg\mod", "User")
$p = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$p;D:\dev\go\bin;D:\dev\gopath\bin", "User")
```
然后**重开一个终端**让变量生效。

- [ ] **Step 3: 验证**

Run: `go version`
Expected: `go version go1.22.5 windows/amd64`

Run: `go env GOPATH GOMODCACHE`
Expected: 两个路径都在 `D:\dev\gopath` 下。

### Task 0.2:安装 Wails CLI

**Files:** 无

- [ ] **Step 1: 安装 Wails CLI(装到 D:\dev\gopath\bin)**

Run: `go install github.com/wailsapp/wails/v2/cmd/wails@latest`
Expected: 完成后 `D:\dev\gopath\bin\wails.exe` 存在(GOPATH 已指 D 盘)。

- [ ] **Step 2: 环境自检**

Run: `wails doctor`
Expected: 报告里 Go、npm 为 OK;WebView2 若缺失按提示安装(Win10/11 一般已自带)。

### Task 0.3:初始化 Wails 项目骨架

**Files:** Create 整个脚手架

- [ ] **Step 1: 在项目目录生成 Wails vanilla 骨架**

当前目录已是 `E:\超-工具\FileTransferTool`。Wails 要求在空目录或指定目录初始化;这里用临时子目录再合并,避免覆盖 docs。

Run(PowerShell):
```powershell
wails init -n filetransfer -t vanilla -d .
```
若 `-d .` 因目录非空报错,则:`wails init -n filetransfer -t vanilla` 生成到 `.\filetransfer`,随后把其中文件(main.go、app.go、go.mod、wails.json、frontend/)移动到项目根,删掉空的 `filetransfer` 目录,保留已有 `docs/`。

Expected: 项目根出现 `main.go`、`app.go`、`go.mod`、`wails.json`、`frontend/`。

- [ ] **Step 2: 把模块名改成可识别的路径**

打开 `go.mod`,把首行模块名改为:
```
module filetransfer
```
(后续所有 import 用 `filetransfer/internal/...`)

- [ ] **Step 3: 跑通空壳**

Run: `wails dev`
Expected: 弹出一个窗口,显示模板默认页面(有个输入框 + Greet 按钮)。确认能出窗口后关掉。

- [ ] **Step 4: 提交(可选,先建 git)**

```bash
git init
git add -A
git commit -m "chore: 初始化 Wails 项目骨架"
```

---

## 阶段 1:本机网络信息(netinfo)

### Task 1.1:取本机局域网 IPv4

**Files:**
- Create: `internal/netinfo/netinfo.go`
- Test: `internal/netinfo/netinfo_test.go`

- [ ] **Step 1: 写失败测试**

`internal/netinfo/netinfo_test.go`:
```go
package netinfo

import "testing"

func TestLocalIPv4_ReturnsPrivateAddress(t *testing.T) {
	ip, err := LocalIPv4()
	if err != nil {
		t.Fatalf("LocalIPv4 报错: %v", err)
	}
	if ip == nil || ip.To4() == nil {
		t.Fatalf("期望一个 IPv4 地址,得到: %v", ip)
	}
	if !ip.IsPrivate() {
		t.Fatalf("期望局域网私有地址(192.168/10/172.16-31),得到: %v", ip)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/netinfo/ -run TestLocalIPv4 -v`
Expected: FAIL，`undefined: LocalIPv4`。

- [ ] **Step 3: 写最小实现**

`internal/netinfo/netinfo.go`:
```go
// Package netinfo 提供本机局域网网络信息:私有 IPv4 与可用端口。
package netinfo

import (
	"errors"
	"net"
)

// LocalIPv4 返回本机第一个非回环的私有 IPv4 地址(供手机/其他电脑连接)。
func LocalIPv4() (net.IP, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP.To4()
			if ip != nil && ip.IsPrivate() {
				return ip, nil
			}
		}
	}
	return nil, errors.New("未找到局域网 IPv4 地址,请检查是否连上了 WiFi/网线")
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/netinfo/ -run TestLocalIPv4 -v`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/netinfo/
git commit -m "feat(netinfo): 取本机局域网 IPv4"
```

### Task 1.2:挑一个可用端口

**Files:**
- Modify: `internal/netinfo/netinfo.go`
- Modify: `internal/netinfo/netinfo_test.go`

- [ ] **Step 1: 追加失败测试**

在 `netinfo_test.go` 追加:
```go
func TestFreePort_IsUsable(t *testing.T) {
	port, err := FreePort()
	if err != nil {
		t.Fatalf("FreePort 报错: %v", err)
	}
	if port <= 0 || port > 65535 {
		t.Fatalf("端口越界: %d", port)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/netinfo/ -run TestFreePort -v`
Expected: FAIL，`undefined: FreePort`。

- [ ] **Step 3: 写实现**

在 `netinfo.go` 追加:
```go
// FreePort 让系统分配一个当前空闲的 TCP 端口并返回其号码。
func FreePort() (int, error) {
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/netinfo/ -v`
Expected: 两个测试都 PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/netinfo/
git commit -m "feat(netinfo): 挑选可用端口"
```

---

## 阶段 2:两级限速器(ratelimit)

### Task 2.1:限速器核心(全局 + 任务两级)

**Files:**
- Create: `internal/ratelimit/limiter.go`
- Test: `internal/ratelimit/limiter_test.go`

设计:`Limiter` 包一个 `*rate.Limiter`(来自 `golang.org/x/time/rate`),`limitBytesPerSec <= 0` 表示不限速。`LimitedReader` 在每次 Read 后,按读到的字节数同时向"全局闸"和"任务闸"申请配额(`WaitN`),从而实现两级约束。

- [ ] **Step 1: 加依赖**

Run: `go get golang.org/x/time/rate`
Expected: `go.mod` 出现该依赖。

- [ ] **Step 2: 写失败测试**

`internal/ratelimit/limiter_test.go`:
```go
package ratelimit

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestLimiter_Unlimited_NoDelay(t *testing.T) {
	l := New(0) // 0 = 不限速
	start := time.Now()
	if err := l.WaitN(context.Background(), 10_000_000); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("不限速时不应有明显等待")
	}
}

func TestLimiter_CapsThroughput(t *testing.T) {
	// 限 1MB/s,读 ~256KB,至少需要约 0.25s。给宽松下限避免 CI 抖动。
	l := New(1 << 20)
	src := strings.NewReader(strings.Repeat("x", 256*1024))
	r := NewLimitedReader(src, l, nil)
	buf := make([]byte, 32*1024)
	start := time.Now()
	total := 0
	for {
		n, err := r.Read(buf)
		total += n
		if err != nil {
			break
		}
	}
	elapsed := time.Since(start)
	if total != 256*1024 {
		t.Fatalf("读取字节数不对: %d", total)
	}
	if elapsed < 150*time.Millisecond {
		t.Fatalf("限速未生效,用时过短: %v", elapsed)
	}
}

func TestLimiter_SetLimit_Runtime(t *testing.T) {
	l := New(1 << 20)
	l.SetLimit(0) // 运行中改成不限速
	start := time.Now()
	if err := l.WaitN(context.Background(), 5_000_000); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("改成不限速后不应等待")
	}
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `go test ./internal/ratelimit/ -v`
Expected: FAIL，`undefined: New` 等。

- [ ] **Step 4: 写实现**

`internal/ratelimit/limiter.go`:
```go
// Package ratelimit 提供可运行时调整的令牌桶限速器,以及限速的 io.Reader。
package ratelimit

import (
	"context"
	"io"
	"sync"

	"golang.org/x/time/rate"
)

// Limiter 包装令牌桶。bytesPerSec <= 0 表示不限速。线程安全。
type Limiter struct {
	mu      sync.Mutex
	lim     *rate.Limiter
	limited bool
}

// New 创建限速器。bytesPerSec <= 0 为不限速。
func New(bytesPerSec int) *Limiter {
	l := &Limiter{}
	l.SetLimit(bytesPerSec)
	return l
}

// SetLimit 运行时调整速率上限(字节/秒)。<=0 表示不限速,立即生效。
func (l *Limiter) SetLimit(bytesPerSec int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if bytesPerSec <= 0 {
		l.limited = false
		l.lim = nil
		return
	}
	l.limited = true
	// 桶容量设为 1 秒的量,允许短突发但长期受限。
	l.lim = rate.NewLimiter(rate.Limit(bytesPerSec), bytesPerSec)
}

// WaitN 阻塞直到可消费 n 字节配额;不限速时立即返回。
func (l *Limiter) WaitN(ctx context.Context, n int) error {
	l.mu.Lock()
	lim := l.lim
	limited := l.limited
	l.mu.Unlock()
	if !limited || n <= 0 {
		return nil
	}
	// rate.Limiter 不允许单次 WaitN 超过桶容量,按容量分批申请。
	burst := lim.Burst()
	for n > 0 {
		step := n
		if step > burst {
			step = burst
		}
		if err := lim.WaitN(ctx, step); err != nil {
			return err
		}
		n -= step
	}
	return nil
}

// LimitedReader 在读取时对全局闸和任务闸同时计量。
type LimitedReader struct {
	r      io.Reader
	global *Limiter // 全局总闸,可为 nil
	task   *Limiter // 任务闸,可为 nil
	ctx    context.Context
}

// NewLimitedReader 包装 r。global/task 任一可为 nil(表示该级不限)。
func NewLimitedReader(r io.Reader, task *Limiter, global *Limiter) *LimitedReader {
	return &LimitedReader{r: r, task: task, global: global, ctx: context.Background()}
}

// WithContext 设置取消用的 context(用于中止传输)。
func (lr *LimitedReader) WithContext(ctx context.Context) *LimitedReader {
	lr.ctx = ctx
	return lr
}

func (lr *LimitedReader) Read(p []byte) (int, error) {
	n, err := lr.r.Read(p)
	if n > 0 {
		if lr.global != nil {
			if werr := lr.global.WaitN(lr.ctx, n); werr != nil {
				return n, werr
			}
		}
		if lr.task != nil {
			if werr := lr.task.WaitN(lr.ctx, n); werr != nil {
				return n, werr
			}
		}
	}
	return n, err
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `go test ./internal/ratelimit/ -v`
Expected: 三个测试全 PASS。

- [ ] **Step 6: 提交**

```bash
git add internal/ratelimit/ go.mod go.sum
git commit -m "feat(ratelimit): 两级令牌桶限速器与限速 Reader"
```

---

## 阶段 3:传输任务模型与断点续传

### Task 3.1:任务模型与状态

**Files:**
- Create: `internal/transfer/task.go`
- Test: `internal/transfer/task_test.go`

- [ ] **Step 1: 写失败测试**

`internal/transfer/task_test.go`:
```go
package transfer

import "testing"

func TestTask_Progress(t *testing.T) {
	tk := &Task{ID: "abc", Name: "a.zip", TotalBytes: 1000, Status: StatusTransferring}
	tk.SetTransferred(250)
	if got := tk.Progress(); got != 0.25 {
		t.Fatalf("进度应为 0.25,得到 %v", got)
	}
}

func TestTask_Progress_ZeroTotal(t *testing.T) {
	tk := &Task{ID: "x", TotalBytes: 0}
	if got := tk.Progress(); got != 0 {
		t.Fatalf("总大小为 0 时进度应为 0,得到 %v", got)
	}
}

func TestTask_CanResume(t *testing.T) {
	tk := &Task{Status: StatusPaused, TransferredBytes: 10, TotalBytes: 100}
	if !tk.CanResume() {
		t.Fatal("已暂停且未传完应可续传")
	}
	done := &Task{Status: StatusDone, TransferredBytes: 100, TotalBytes: 100}
	if done.CanResume() {
		t.Fatal("已完成不应可续传")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/transfer/ -run TestTask -v`
Expected: FAIL，未定义类型。

- [ ] **Step 3: 写实现**

`internal/transfer/task.go`:
```go
// Package transfer 定义传输任务模型、状态机与断点续传逻辑。
package transfer

import "sync/atomic"

// Status 是任务状态。
type Status string

const (
	StatusPending      Status = "pending"      // 等接收方确认
	StatusTransferring Status = "transferring" // 传输中
	StatusPaused       Status = "paused"       // 已暂停(可续传)
	StatusDone         Status = "done"         // 已完成
	StatusFailed       Status = "failed"       // 失败
	StatusRejected     Status = "rejected"     // 被接收方拒绝
)

// Direction 表示方向(相对本机)。
type Direction string

const (
	DirSend Direction = "send" // 本机发出
	DirRecv Direction = "recv" // 本机接收
)

// Task 一个文件的传输任务。TransferredBytes 用原子操作以便进度协程读取。
type Task struct {
	ID               string    `json:"id"`
	Name             string    `json:"name"`     // 显示名(文件名)
	RelPath          string    `json:"relPath"`  // 相对路径(文件夹传输时重建目录用)
	TotalBytes       int64     `json:"totalBytes"`
	TransferredBytes int64     `json:"transferredBytes"`
	Status           Status    `json:"status"`
	Direction        Direction `json:"direction"`
	Peer             string    `json:"peer"`         // 对端名字/地址
	LimitBytesPerSec int       `json:"limitBps"`     // 本任务限速,0=不限
	Err              string    `json:"err,omitempty"`
}

// SetTransferred 原子设置已传字节。
func (t *Task) SetTransferred(n int64) { atomic.StoreInt64(&t.TransferredBytes, n) }

// AddTransferred 原子累加并返回新值。
func (t *Task) AddTransferred(n int64) int64 { return atomic.AddInt64(&t.TransferredBytes, n) }

// Loaded 原子读取已传字节。
func (t *Task) Loaded() int64 { return atomic.LoadInt64(&t.TransferredBytes) }

// Progress 返回 0~1 的进度。
func (t *Task) Progress() float64 {
	if t.TotalBytes <= 0 {
		return 0
	}
	return float64(t.Loaded()) / float64(t.TotalBytes)
}

// CanResume 是否可续传:未完成且已传 < 总量。
func (t *Task) CanResume() bool {
	if t.Status == StatusDone || t.Status == StatusRejected {
		return false
	}
	return t.Loaded() < t.TotalBytes
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/transfer/ -run TestTask -v`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/transfer/task.go internal/transfer/task_test.go
git commit -m "feat(transfer): 任务模型与状态机"
```

### Task 3.2:断点续传偏移计算

**Files:**
- Create: `internal/transfer/resume.go`
- Test: `internal/transfer/resume_test.go`

设计:接收落盘到一个临时文件 `<dest>.part`。续传时偏移 = 已有 `.part` 文件大小。提供函数算出"应从哪个字节开始接着写",并打开文件到追加位置。

- [ ] **Step 1: 写失败测试**

`internal/transfer/resume_test.go`:
```go
package transfer

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResumeOffset_NoPartFile_IsZero(t *testing.T) {
	dir := t.TempDir()
	off, err := ResumeOffset(filepath.Join(dir, "a.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if off != 0 {
		t.Fatalf("无 .part 文件时偏移应为 0,得到 %d", off)
	}
}

func TestResumeOffset_ExistingPart_ReturnsSize(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "a.bin")
	if err := os.WriteFile(dest+".part", []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	off, err := ResumeOffset(dest)
	if err != nil {
		t.Fatal(err)
	}
	if off != 5 {
		t.Fatalf("偏移应为 5,得到 %d", off)
	}
}

func TestOpenForResume_AppendsAtOffset(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "sub", "a.bin") // 目录不存在,应自动建
	f, off, err := OpenForResume(dest)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if off != 0 {
		t.Fatalf("新文件偏移应为 0,得到 %d", off)
	}
	if _, err := f.WriteString("world"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dest + ".part"); err != nil {
		t.Fatalf(".part 文件应存在: %v", err)
	}
}

func TestFinalize_RenamesPartToDest(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "a.bin")
	if err := os.WriteFile(dest+".part", []byte("done"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Finalize(dest); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dest); err != nil {
		t.Fatalf("最终文件应存在: %v", err)
	}
	if _, err := os.Stat(dest + ".part"); !os.IsNotExist(err) {
		t.Fatal(".part 文件应已被改名删除")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/transfer/ -run "Resume|OpenForResume|Finalize" -v`
Expected: FAIL，未定义函数。

- [ ] **Step 3: 写实现**

`internal/transfer/resume.go`:
```go
package transfer

import (
	"os"
	"path/filepath"
)

// partSuffix 是接收中临时文件的后缀。
const partSuffix = ".part"

// ResumeOffset 返回 dest 对应 .part 文件已有的大小(即续传起点);无则返回 0。
func ResumeOffset(dest string) (int64, error) {
	fi, err := os.Stat(dest + partSuffix)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return fi.Size(), nil
}

// OpenForResume 打开(或创建)dest 的 .part 文件,定位到末尾以便追加写入。
// 自动创建所需的父目录。返回文件句柄与当前偏移。
func OpenForResume(dest string) (*os.File, int64, error) {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return nil, 0, err
	}
	f, err := os.OpenFile(dest+partSuffix, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, 0, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	return f, fi.Size(), nil
}

// Finalize 在接收完成后,把 dest.part 改名为 dest。
func Finalize(dest string) error {
	return os.Rename(dest+partSuffix, dest)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/transfer/ -v`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/transfer/resume.go internal/transfer/resume_test.go
git commit -m "feat(transfer): 断点续传偏移与临时文件落盘"
```

### Task 3.3:任务管理器

**Files:**
- Create: `internal/transfer/manager.go`
- Test: `internal/transfer/manager_test.go`

设计:`Manager` 管理所有任务(并发安全 map),持有全局限速 `Limiter`。提供新增、查询、列出、更新状态、设置全局/任务限速、注册"变更回调"(用于把进度推给 UI)。

- [ ] **Step 1: 写失败测试**

`internal/transfer/manager_test.go`:
```go
package transfer

import (
	"testing"
)

func TestManager_AddAndGet(t *testing.T) {
	m := NewManager(0)
	tk := m.Add(&Task{ID: "t1", Name: "a", TotalBytes: 100, Direction: DirRecv})
	got, ok := m.Get("t1")
	if !ok || got != tk {
		t.Fatal("应能取回刚加入的任务")
	}
}

func TestManager_List(t *testing.T) {
	m := NewManager(0)
	m.Add(&Task{ID: "t1"})
	m.Add(&Task{ID: "t2"})
	if len(m.List()) != 2 {
		t.Fatalf("应有 2 个任务,得到 %d", len(m.List()))
	}
}

func TestManager_GlobalLimit(t *testing.T) {
	m := NewManager(1 << 20)
	m.SetGlobalLimit(0) // 不应 panic;运行时可调
	if m.GlobalLimiter() == nil {
		t.Fatal("全局限速器不应为 nil")
	}
}

func TestManager_TaskLimit(t *testing.T) {
	m := NewManager(0)
	m.Add(&Task{ID: "t1"})
	m.SetTaskLimit("t1", 500_000)
	got, _ := m.Get("t1")
	if got.LimitBytesPerSec != 500_000 {
		t.Fatalf("任务限速应为 500000,得到 %d", got.LimitBytesPerSec)
	}
	if m.TaskLimiter("t1") == nil {
		t.Fatal("任务限速器不应为 nil")
	}
}

func TestManager_OnChange_Fires(t *testing.T) {
	m := NewManager(0)
	fired := 0
	m.OnChange(func(_ *Task) { fired++ })
	m.Add(&Task{ID: "t1"})
	m.Touch("t1")
	if fired < 1 {
		t.Fatal("OnChange 回调应至少触发一次")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/transfer/ -run TestManager -v`
Expected: FAIL，未定义 `NewManager` 等。

- [ ] **Step 3: 写实现**

`internal/transfer/manager.go`:
```go
package transfer

import (
	"sync"

	"filetransfer/internal/ratelimit"
)

// ChangeFunc 任务变更回调(用于把进度/状态推给 UI)。
type ChangeFunc func(*Task)

// Manager 管理全部传输任务与限速器,并发安全。
type Manager struct {
	mu        sync.RWMutex
	tasks     map[string]*Task
	taskLims  map[string]*ratelimit.Limiter
	global    *ratelimit.Limiter
	onChange  []ChangeFunc
}

// NewManager 创建管理器,globalBps 为全局限速(0=不限)。
func NewManager(globalBps int) *Manager {
	return &Manager{
		tasks:    make(map[string]*Task),
		taskLims: make(map[string]*ratelimit.Limiter),
		global:   ratelimit.New(globalBps),
	}
}

// Add 加入任务并返回它(同时为其建一个任务级限速器)。
func (m *Manager) Add(t *Task) *Task {
	m.mu.Lock()
	m.tasks[t.ID] = t
	m.taskLims[t.ID] = ratelimit.New(t.LimitBytesPerSec)
	m.mu.Unlock()
	m.fire(t)
	return t
}

// Get 取任务。
func (m *Manager) Get(id string) (*Task, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	t, ok := m.tasks[id]
	return t, ok
}

// List 返回所有任务的快照切片。
func (m *Manager) List() []*Task {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]*Task, 0, len(m.tasks))
	for _, t := range m.tasks {
		out = append(out, t)
	}
	return out
}

// GlobalLimiter 返回全局限速器。
func (m *Manager) GlobalLimiter() *ratelimit.Limiter { return m.global }

// SetGlobalLimit 运行时调整全局限速(字节/秒,0=不限)。
func (m *Manager) SetGlobalLimit(bps int) { m.global.SetLimit(bps) }

// TaskLimiter 返回某任务的限速器(不存在则 nil)。
func (m *Manager) TaskLimiter(id string) *ratelimit.Limiter {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.taskLims[id]
}

// SetTaskLimit 运行时调整某任务限速。
func (m *Manager) SetTaskLimit(id string, bps int) {
	m.mu.Lock()
	if t, ok := m.tasks[id]; ok {
		t.LimitBytesPerSec = bps
	}
	if l, ok := m.taskLims[id]; ok {
		l.SetLimit(bps)
	}
	t := m.tasks[id]
	m.mu.Unlock()
	if t != nil {
		m.fire(t)
	}
}

// SetStatus 改状态并触发回调。
func (m *Manager) SetStatus(id string, s Status, errMsg string) {
	m.mu.Lock()
	t, ok := m.tasks[id]
	if ok {
		t.Status = s
		if errMsg != "" {
			t.Err = errMsg
		}
	}
	m.mu.Unlock()
	if ok {
		m.fire(t)
	}
}

// Touch 主动触发一次变更回调(用于进度推送)。
func (m *Manager) Touch(id string) {
	if t, ok := m.Get(id); ok {
		m.fire(t)
	}
}

// OnChange 注册任务变更回调。
func (m *Manager) OnChange(fn ChangeFunc) {
	m.mu.Lock()
	m.onChange = append(m.onChange, fn)
	m.mu.Unlock()
}

func (m *Manager) fire(t *Task) {
	m.mu.RLock()
	cbs := make([]ChangeFunc, len(m.onChange))
	copy(cbs, m.onChange)
	m.mu.RUnlock()
	for _, fn := range cbs {
		fn(t)
	}
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/transfer/ -v`
Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/transfer/manager.go internal/transfer/manager_test.go
git commit -m "feat(transfer): 任务管理器与限速联动"
```

---

## 阶段 4:二维码

### Task 4.1:生成二维码 dataURL

**Files:**
- Create: `internal/qrcode/qrcode.go`
- Test: `internal/qrcode/qrcode_test.go`

- [ ] **Step 1: 加依赖**

Run: `go get github.com/skip2/go-qrcode`
Expected: `go.mod` 出现该依赖。

- [ ] **Step 2: 写失败测试**

`internal/qrcode/qrcode_test.go`:
```go
package qrcode

import (
	"strings"
	"testing"
)

func TestDataURL_PNGPrefix(t *testing.T) {
	url, err := DataURL("http://192.168.1.5:8080/?t=abc", 256)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(url, "data:image/png;base64,") {
		t.Fatalf("应为 PNG dataURL,得到前缀: %.30s", url)
	}
	if len(url) < 100 {
		t.Fatal("dataURL 看起来太短,可能没生成图")
	}
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `go test ./internal/qrcode/ -v`
Expected: FAIL，`undefined: DataURL`。

- [ ] **Step 4: 写实现**

`internal/qrcode/qrcode.go`:
```go
// Package qrcode 把文本生成为二维码 PNG 的 base64 dataURL,供前端 <img> 直接显示。
package qrcode

import (
	"encoding/base64"

	qr "github.com/skip2/go-qrcode"
)

// DataURL 把 content 生成 size 像素见方的二维码,返回 data:image/png;base64,... 字符串。
func DataURL(content string, size int) (string, error) {
	png, err := qr.Encode(content, qr.Medium, size)
	if err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), nil
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `go test ./internal/qrcode/ -v`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add internal/qrcode/ go.mod go.sum
git commit -m "feat(qrcode): 生成二维码 dataURL"
```

---

## 阶段 5:HTTP/WS 服务与手机端页面

> 本阶段是集成性的:HTTP handler 用 `httptest` 单测核心路径,WS 与页面靠手动验证。所有 API 同时服务"手机网页"和"电脑↔电脑"。

### API 约定(贯穿后续任务)

- `GET /` → 手机端页面(需带一次性 token:`/?t=<token>`,token 不符返回 401)
- `GET /api/health` → `{"ok":true,"name":"<本机名>"}`
- `POST /api/offer` → 发送方先报告将要发的文件(名字、大小、相对路径列表),服务端建 `pending` 任务,经 WS 通知接收端 UI 弹窗;返回 `offerId`
- `GET /api/offer/{id}/wait` → 长轮询/或前端走 WS 得知 accept/reject(实际用 WS 推送,见 ws.go)
- `POST /api/offer/{id}/accept` / `POST /api/offer/{id}/reject` → 接收端 UI 点按后调用
- `PUT /api/upload?id=<taskId>` → 上传文件体;支持 `Content-Range: bytes <start>-/<total>` 续传;服务端落盘到 `.part` 并更新进度;完成后 `Finalize`
- `GET /api/upload/status?id=<taskId>` → 返回已落盘偏移(供续传前查询)
- `GET /api/download?id=<taskId>` → 下载文件;支持 `Range` 头续传;读取时套两级限速 Reader
- `GET /ws?t=<token>` → WebSocket,推送任务进度、状态、接收确认请求

token 在服务启动时随机生成一个会话级字符串,二维码 URL 带上它。

### Task 5.1:服务骨架与 health

**Files:**
- Create: `internal/server/server.go`
- Test: `internal/server/server_test.go`

- [ ] **Step 1: 写失败测试**

`internal/server/server_test.go`:
```go
package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"filetransfer/internal/transfer"
)

func newTestServer() *Server {
	return New(transfer.NewManager(0), "test-host", "tok123", t_tempDir())
}

// 用包级变量便于测试覆盖保存目录;真实运行由 main 注入。
func t_tempDir() string { return "." }

func TestHealth_OK(t *testing.T) {
	s := newTestServer()
	req := httptest.NewRequest("GET", "/api/health", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码应 200,得到 %d", rec.Code)
	}
	var body struct {
		OK   bool   `json:"ok"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.OK || body.Name != "test-host" {
		t.Fatalf("health 内容不对: %+v", body)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/server/ -run TestHealth -v`
Expected: FAIL，未定义 `New`/`Server`。

- [ ] **Step 3: 写实现**

`internal/server/server.go`:
```go
// Package server 提供局域网内置 HTTP/WS 服务,供手机浏览器与其他电脑收发文件。
package server

import (
	"encoding/json"
	"net/http"

	"filetransfer/internal/transfer"
)

// Server 持有依赖并装配路由。
type Server struct {
	mgr      *transfer.Manager
	hostName string
	token    string // 会话级一次性令牌
	saveDir  string // 接收文件保存目录
	mux      *http.ServeMux
}

// New 创建服务。saveDir 为接收文件落盘根目录。
func New(mgr *transfer.Manager, hostName, token, saveDir string) *Server {
	s := &Server{mgr: mgr, hostName: hostName, token: token, saveDir: saveDir, mux: http.NewServeMux()}
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux.HandleFunc("/api/health", s.handleHealth)
	// 其余路由在后续任务接入:offer/upload/download/ws/根页面
}

// Handler 返回顶层 http.Handler(便于测试)。
func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "name": s.hostName})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/server/ -run TestHealth -v`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/server/server.go internal/server/server_test.go
git commit -m "feat(server): 服务骨架与 health 接口"
```

### Task 5.2:token 校验中间件与根页面

**Files:**
- Modify: `internal/server/server.go`
- Create: `internal/server/web/mobile.html`(占位最小页面,后续 Task 5.6 完善)
- Modify: `internal/server/server_test.go`

- [ ] **Step 1: 追加失败测试**

在 `server_test.go` 追加:
```go
func TestRoot_RequiresToken(t *testing.T) {
	s := newTestServer()
	// 无 token
	req := httptest.NewRequest("GET", "/", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("无 token 应 401,得到 %d", rec.Code)
	}
	// 正确 token
	req2 := httptest.NewRequest("GET", "/?t=tok123", nil)
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("带正确 token 应 200,得到 %d", rec2.Code)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/server/ -run TestRoot -v`
Expected: FAIL(根路由未注册,返回 404)。

- [ ] **Step 3: 写最小手机页面占位**

`internal/server/web/mobile.html`:
```html
<!doctype html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>文件互传</title></head>
<body><h1>文件互传</h1><p>页面将在 Task 5.6 完善。</p></body></html>
```

- [ ] **Step 4: 写实现(embed + token 中间件 + 根路由)**

在 `server.go` 顶部 import 区加入 `"embed"` 与 `"io/fs"`,并在包级加入 embed:
```go
//go:embed web/*
var webFS embed.FS
```
在 `routes()` 里追加:
```go
	s.mux.HandleFunc("/", s.requireToken(s.handleRoot))
```
新增方法:
```go
// requireToken 是中间件:校验 URL 查询参数 t 是否等于会话 token。
func (s *Server) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("t") != s.token {
			http.Error(w, "无效或缺失的连接码", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	data, err := fs.ReadFile(webFS, "web/mobile.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(data)
}
```
确保 import 列表含 `"embed"`、`"io/fs"`。

- [ ] **Step 5: 跑测试确认通过**

Run: `go test ./internal/server/ -v`
Expected: 全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add internal/server/
git commit -m "feat(server): token 校验与手机端根页面(占位)"
```

### Task 5.3:上传接收(支持 Content-Range 续传)

**Files:**
- Create: `internal/server/handlers.go`
- Modify: `internal/server/server.go`(注册路由)
- Test: `internal/server/handlers_test.go`

- [ ] **Step 1: 写失败测试(全量上传 + 续传两段)**

`internal/server/handlers_test.go`:
```go
package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"filetransfer/internal/transfer"
)

func serverWithDir(dir string) *Server {
	mgr := transfer.NewManager(0)
	mgr.Add(&transfer.Task{ID: "u1", Name: "a.bin", RelPath: "a.bin", TotalBytes: 10, Direction: transfer.DirRecv, Status: transfer.StatusTransferring})
	return New(mgr, "host", "tok123", dir)
}

func TestUpload_FullThenFinalize(t *testing.T) {
	dir := t.TempDir()
	s := serverWithDir(dir)
	body := bytes.NewReader([]byte("0123456789")) // 10 字节,等于 TotalBytes
	req := httptest.NewRequest("PUT", "/api/upload?id=u1", body)
	req.Header.Set("Content-Range", "bytes 0-/10")
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("应 200,得到 %d,体: %s", rec.Code, rec.Body.String())
	}
	got, err := os.ReadFile(filepath.Join(dir, "a.bin"))
	if err != nil {
		t.Fatalf("最终文件应存在: %v", err)
	}
	if string(got) != "0123456789" {
		t.Fatalf("内容不对: %q", got)
	}
}

func TestUpload_ResumeSecondHalf(t *testing.T) {
	dir := t.TempDir()
	s := serverWithDir(dir)
	// 先传前 4 字节
	req1 := httptest.NewRequest("PUT", "/api/upload?id=u1", bytes.NewReader([]byte("0123")))
	req1.Header.Set("Content-Range", "bytes 0-/10")
	rec1 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec1, req1)
	// 查询已传偏移
	reqS := httptest.NewRequest("GET", "/api/upload/status?id=u1", nil)
	recS := httptest.NewRecorder()
	s.Handler().ServeHTTP(recS, reqS)
	if !bytes.Contains(recS.Body.Bytes(), []byte("\"offset\":4")) {
		t.Fatalf("偏移应为 4,得到 %s", recS.Body.String())
	}
	// 从偏移 4 续传剩余
	req2 := httptest.NewRequest("PUT", "/api/upload?id=u1", bytes.NewReader([]byte("456789")))
	req2.Header.Set("Content-Range", "bytes 4-/10")
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, req2)
	got, _ := os.ReadFile(filepath.Join(dir, "a.bin"))
	if string(got) != "0123456789" {
		t.Fatalf("续传后内容不对: %q", got)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/server/ -run TestUpload -v`
Expected: FAIL(路由未注册)。

- [ ] **Step 3: 写实现**

`internal/server/handlers.go`:
```go
package server

import (
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"filetransfer/internal/ratelimit"
	"filetransfer/internal/transfer"
)

// parseContentRangeStart 从 "bytes <start>-/<total>" 解析起始偏移。无该头返回 0。
func parseContentRangeStart(h string) (int64, error) {
	if h == "" {
		return 0, nil
	}
	h = strings.TrimPrefix(h, "bytes ")
	dash := strings.IndexByte(h, '-')
	if dash < 0 {
		return 0, fmt.Errorf("非法 Content-Range: %q", h)
	}
	return strconv.ParseInt(h[:dash], 10, 64)
}

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	tk, ok := s.mgr.Get(id)
	if !ok {
		http.Error(w, "未知任务", http.StatusNotFound)
		return
	}
	dest := filepath.Join(s.saveDir, filepath.FromSlash(tk.RelPath))
	f, off, err := transfer.OpenForResume(dest)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer f.Close()
	tk.SetTransferred(off)

	// 接收方向也套两级限速(限制对方上传占用本机带宽)。
	reader := ratelimit.NewLimitedReader(r.Body, s.mgr.TaskLimiter(id), s.mgr.GlobalLimiter()).
		WithContext(r.Context())

	buf := make([]byte, 64*1024)
	for {
		n, rerr := reader.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				s.mgr.SetStatus(id, transfer.StatusFailed, werr.Error())
				http.Error(w, werr.Error(), http.StatusInternalServerError)
				return
			}
			tk.AddTransferred(int64(n))
			s.mgr.Touch(id)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			s.mgr.SetStatus(id, transfer.StatusPaused, rerr.Error())
			http.Error(w, rerr.Error(), http.StatusBadGateway)
			return
		}
	}

	if tk.Loaded() >= tk.TotalBytes {
		if err := transfer.Finalize(dest); err != nil {
			s.mgr.SetStatus(id, transfer.StatusFailed, err.Error())
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		s.mgr.SetStatus(id, transfer.StatusDone, "")
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "received": tk.Loaded()})
}

func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	tk, ok := s.mgr.Get(id)
	if !ok {
		http.Error(w, "未知任务", http.StatusNotFound)
		return
	}
	dest := filepath.Join(s.saveDir, filepath.FromSlash(tk.RelPath))
	off, err := transfer.ResumeOffset(dest)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"offset": off})
}
```
在 `server.go` 的 `routes()` 追加:
```go
	s.mux.HandleFunc("/api/upload", s.handleUpload)
	s.mux.HandleFunc("/api/upload/status", s.handleUploadStatus)
```
(注:测试里 `parseContentRangeStart` 暂未直接用于 handler 逻辑;偏移以服务端 `.part` 实际大小为准,客户端 Content-Range 用于自检。保留该函数供 Task 5.4 下载方向与客户端复用。)

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/server/ -run TestUpload -v`
Expected: 两个测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/server/
git commit -m "feat(server): 文件上传接收与续传偏移查询"
```

### Task 5.4:下载发送(支持 Range + 限速)

**Files:**
- Modify: `internal/server/handlers.go`
- Modify: `internal/server/server.go`
- Modify: `internal/server/handlers_test.go`

- [ ] **Step 1: 追加失败测试**

在 `handlers_test.go` 追加:
```go
func TestDownload_FullAndRange(t *testing.T) {
	dir := t.TempDir()
	// 准备一个可下载的源文件,并登记 send 任务
	src := filepath.Join(dir, "send.bin")
	if err := os.WriteFile(src, []byte("ABCDEFGHIJ"), 0o644); err != nil {
		t.Fatal(err)
	}
	mgr := transfer.NewManager(0)
	mgr.Add(&transfer.Task{ID: "d1", Name: "send.bin", TotalBytes: 10, Direction: transfer.DirSend, Status: transfer.StatusTransferring})
	s := New(mgr, "host", "tok123", dir)
	s.RegisterSendFile("d1", src) // 告诉服务端 d1 对应的本地源文件路径

	// 全量
	req := httptest.NewRequest("GET", "/api/download?id=d1", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Body.String() != "ABCDEFGHIJ" {
		t.Fatalf("全量内容不对: %q", rec.Body.String())
	}
	// Range: 从第 4 字节
	req2 := httptest.NewRequest("GET", "/api/download?id=d1", nil)
	req2.Header.Set("Range", "bytes=4-")
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusPartialContent {
		t.Fatalf("Range 请求应 206,得到 %d", rec2.Code)
	}
	if rec2.Body.String() != "EFGHIJ" {
		t.Fatalf("Range 内容不对: %q", rec2.Body.String())
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/server/ -run TestDownload -v`
Expected: FAIL(`RegisterSendFile`/路由未定义)。

- [ ] **Step 3: 写实现**

在 `Server` 结构体加一个发送文件映射。修改 `server.go` 的结构体与 New:
```go
// 在 import 加 "sync"
// Server 结构体加字段:
//   sendFiles map[string]string // taskID -> 本地源文件绝对路径
//   sendMu    sync.RWMutex
// New 里初始化:s.sendFiles = make(map[string]string)
```
具体:把 `Server` 定义改为含:
```go
type Server struct {
	mgr       *transfer.Manager
	hostName  string
	token     string
	saveDir   string
	mux       *http.ServeMux
	sendFiles map[string]string
	sendMu    sync.RWMutex
}
```
`New` 中 `s := &Server{... , sendFiles: make(map[string]string)}`。

在 `handlers.go` 追加:
```go
import 增加 "os"

// RegisterSendFile 登记某 send 任务对应的本地源文件路径。
func (s *Server) RegisterSendFile(taskID, absPath string) {
	s.sendMu.Lock()
	s.sendFiles[taskID] = absPath
	s.sendMu.Unlock()
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	s.sendMu.RLock()
	path, ok := s.sendFiles[id]
	s.sendMu.RUnlock()
	if !ok {
		http.Error(w, "未知下载任务", http.StatusNotFound)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	total := fi.Size()

	start, _ := parseRangeStart(r.Header.Get("Range"))
	if start > 0 {
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			http.Error(w, err.Error(), http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, total-1, total))
		w.Header().Set("Content-Length", strconv.FormatInt(total-start, 10))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
	}

	if tk, ok := s.mgr.Get(id); ok {
		tk.SetTransferred(start)
	}
	reader := ratelimit.NewLimitedReader(f, s.mgr.TaskLimiter(id), s.mgr.GlobalLimiter()).
		WithContext(r.Context())
	buf := make([]byte, 64*1024)
	for {
		n, rerr := reader.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if tk, ok := s.mgr.Get(id); ok {
				tk.AddTransferred(int64(n))
				s.mgr.Touch(id)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return
		}
	}
	if tk, ok := s.mgr.Get(id); ok && tk.Loaded() >= tk.TotalBytes {
		s.mgr.SetStatus(id, transfer.StatusDone, "")
	}
}

// parseRangeStart 解析 "bytes=<start>-" 的起始偏移。
func parseRangeStart(h string) (int64, error) {
	if h == "" {
		return 0, nil
	}
	h = strings.TrimPrefix(h, "bytes=")
	dash := strings.IndexByte(h, '-')
	if dash < 0 {
		return 0, fmt.Errorf("非法 Range: %q", h)
	}
	return strconv.ParseInt(h[:dash], 10, 64)
}
```
`routes()` 追加:
```go
	s.mux.HandleFunc("/api/download", s.handleDownload)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `go test ./internal/server/ -run TestDownload -v`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add internal/server/
git commit -m "feat(server): 文件下载发送,支持 Range 与限速"
```

### Task 5.5:接收确认(offer/accept/reject)+ WebSocket 推送

**Files:**
- Create: `internal/server/ws.go`
- Modify: `internal/server/handlers.go`、`internal/server/server.go`
- Modify: `internal/server/handlers_test.go`

设计:`offer` 把待传文件列表登记为多个 `pending` 任务并通过 WS 广播 `offer` 事件;`accept` 把这些任务置 `transferring` 并广播;`reject` 置 `rejected`。WS hub 维护已连接客户端,`Manager.OnChange` 注册一个回调把任务变更广播给所有 WS 客户端(进度实时更新)。

- [ ] **Step 1: 加 WS 依赖**

Run: `go get github.com/gorilla/websocket`
Expected: `go.mod` 出现该依赖。

- [ ] **Step 2: 写失败测试(offer 建任务 + accept 改状态)**

在 `handlers_test.go` 追加:
```go
func TestOffer_CreatesPendingThenAccept(t *testing.T) {
	dir := t.TempDir()
	mgr := transfer.NewManager(0)
	s := New(mgr, "host", "tok123", dir)

	body := bytes.NewBufferString(`{"peer":"phone","files":[{"id":"o1","name":"a.bin","relPath":"a.bin","totalBytes":5}]}`)
	req := httptest.NewRequest("POST", "/api/offer", body)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("offer 应 200,得到 %d: %s", rec.Code, rec.Body.String())
	}
	tk, ok := mgr.Get("o1")
	if !ok || tk.Status != transfer.StatusPending {
		t.Fatalf("应建出 pending 任务,得到 %+v", tk)
	}
	// accept
	reqA := httptest.NewRequest("POST", "/api/offer/o1/accept", nil)
	recA := httptest.NewRecorder()
	s.Handler().ServeHTTP(recA, reqA)
	tk2, _ := mgr.Get("o1")
	if tk2.Status != transfer.StatusTransferring {
		t.Fatalf("accept 后应为 transferring,得到 %s", tk2.Status)
	}
}

func TestOffer_Reject(t *testing.T) {
	dir := t.TempDir()
	mgr := transfer.NewManager(0)
	s := New(mgr, "host", "tok123", dir)
	mgr.Add(&transfer.Task{ID: "o2", Status: transfer.StatusPending})
	req := httptest.NewRequest("POST", "/api/offer/o2/reject", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	tk, _ := mgr.Get("o2")
	if tk.Status != transfer.StatusRejected {
		t.Fatalf("reject 后应为 rejected,得到 %s", tk.Status)
	}
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `go test ./internal/server/ -run TestOffer -v`
Expected: FAIL(路由未定义)。

- [ ] **Step 4: 写 WS hub**

`internal/server/ws.go`:
```go
package server

import (
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true }, // 局域网工具,放开同源限制
}

// hub 维护所有 WS 客户端,广播 JSON 消息。
type hub struct {
	mu    sync.RWMutex
	conns map[*websocket.Conn]struct{}
}

func newHub() *hub { return &hub{conns: make(map[*websocket.Conn]struct{})} }

func (h *hub) add(c *websocket.Conn) {
	h.mu.Lock()
	h.conns[c] = struct{}{}
	h.mu.Unlock()
}

func (h *hub) remove(c *websocket.Conn) {
	h.mu.Lock()
	delete(h.conns, c)
	h.mu.Unlock()
	_ = c.Close()
}

// broadcast 向所有客户端发送一条 JSON 消息(类型 + 负载)。
func (h *hub) broadcast(msgType string, payload any) {
	msg := map[string]any{"type": msgType, "data": payload}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.conns {
		_ = c.WriteJSON(msg)
	}
}
```

- [ ] **Step 5: 写 offer/accept/reject/ws handler 并接线**

在 `server.go` 的 `Server` 结构体加 `hub *hub` 字段;`New` 里 `s.hub = newHub()`,并注册把任务变更广播出去:
```go
	s.mgr.OnChange(func(t *transfer.Task) {
		s.hub.broadcast("task", t)
	})
```
`routes()` 追加:
```go
	s.mux.HandleFunc("/api/offer", s.handleOffer)
	s.mux.HandleFunc("/api/offer/", s.handleOfferAction) // /api/offer/{id}/accept|reject
	s.mux.HandleFunc("/ws", s.handleWS)
```
在 `handlers.go` 追加(import 增加 `"encoding/json"`):
```go
type offerFile struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	RelPath    string `json:"relPath"`
	TotalBytes int64  `json:"totalBytes"`
}
type offerReq struct {
	Peer  string      `json:"peer"`
	Files []offerFile `json:"files"`
}

func (s *Server) handleOffer(w http.ResponseWriter, r *http.Request) {
	var req offerReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	for _, fdef := range req.Files {
		s.mgr.Add(&transfer.Task{
			ID: fdef.ID, Name: fdef.Name, RelPath: fdef.RelPath,
			TotalBytes: fdef.TotalBytes, Direction: transfer.DirRecv,
			Peer: req.Peer, Status: transfer.StatusPending,
		})
	}
	s.hub.broadcast("offer", req)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleOfferAction 处理 /api/offer/{id}/accept 与 /reject。
func (s *Server) handleOfferAction(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/offer/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 {
		http.Error(w, "路径不对", http.StatusBadRequest)
		return
	}
	id, action := parts[0], parts[1]
	switch action {
	case "accept":
		s.mgr.SetStatus(id, transfer.StatusTransferring, "")
	case "reject":
		s.mgr.SetStatus(id, transfer.StatusRejected, "")
	default:
		http.Error(w, "未知操作", http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	s.hub.add(c)
	defer s.hub.remove(c)
	// 连上先把当前任务快照发过去
	for _, t := range s.mgr.List() {
		_ = c.WriteJSON(map[string]any{"type": "task", "data": t})
	}
	// 读循环(忽略客户端消息,仅用于探测断开)
	for {
		if _, _, err := c.ReadMessage(); err != nil {
			return
		}
	}
}
```

- [ ] **Step 6: 跑测试确认通过**

Run: `go test ./internal/server/ -v`
Expected: 全部 PASS(WS 本身不在单测覆盖,offer/accept/reject 通过)。

- [ ] **Step 7: 提交**

```bash
git add internal/server/ go.mod go.sum
git commit -m "feat(server): 接收确认 offer/accept/reject 与 WS 进度广播"
```

### Task 5.6:手机端页面(响应式 H5)

**Files:**
- Modify: `internal/server/web/mobile.html`
- Create: `internal/server/web/mobile.css`、`internal/server/web/mobile.js`
- Modify: `internal/server/server.go`(把 css/js 也按静态资源提供)

> 本任务以手动验证为主(浏览器实际操作);无单元测试。

- [ ] **Step 1: 让根路由也能提供 css/js 静态文件**

在 `server.go` 把 `handleRoot` 改为按路径分发静态资源(仍受 token 中间件保护)。把 `routes()` 中根路由保持 `s.mux.HandleFunc("/", s.requireToken(s.handleStatic))`,并实现:
```go
func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	if name == "" {
		name = "mobile.html"
	}
	data, err := fs.ReadFile(webFS, "web/"+name)
	if err != nil {
		http.Error(w, "404", http.StatusNotFound)
		return
	}
	switch {
	case strings.HasSuffix(name, ".html"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	case strings.HasSuffix(name, ".css"):
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	case strings.HasSuffix(name, ".js"):
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	}
	_, _ = w.Write(data)
}
```
(删除旧的 `handleRoot` 或保留不再引用。)

- [ ] **Step 2: 写手机页面**

`internal/server/web/mobile.html`:
```html
<!doctype html>
<html lang="zh"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>文件互传</title>
<link rel="stylesheet" href="mobile.css">
</head><body>
<header><h1>文件互传</h1><span id="host"></span></header>
<main>
  <section class="card">
    <h2>发到电脑</h2>
    <input type="file" id="picker" multiple>
    <button id="sendBtn">发送</button>
  </section>
  <section class="card">
    <h2>传输任务</h2>
    <ul id="tasks"></ul>
  </section>
</main>
<script src="mobile.js"></script>
</body></html>
```
`internal/server/web/mobile.css`:
```css
* { box-sizing: border-box; }
body { margin:0; font-family: system-ui, sans-serif; background:#f5f6f8; color:#222; }
header { background:#2d6cdf; color:#fff; padding:14px 16px; display:flex; justify-content:space-between; align-items:center; }
header h1 { font-size:18px; margin:0; }
main { padding:12px; max-width:680px; margin:0 auto; }
.card { background:#fff; border-radius:10px; padding:14px; margin-bottom:12px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
.card h2 { font-size:15px; margin:0 0 10px; }
button { background:#2d6cdf; color:#fff; border:0; border-radius:8px; padding:10px 16px; font-size:15px; }
ul { list-style:none; padding:0; margin:0; }
li { padding:8px 0; border-bottom:1px solid #eee; }
.bar { height:6px; background:#e6e8eb; border-radius:3px; overflow:hidden; margin-top:6px; }
.bar > i { display:block; height:100%; background:#2d6cdf; width:0; }
.meta { font-size:12px; color:#666; display:flex; justify-content:space-between; margin-top:4px; }
```
`internal/server/web/mobile.js`(用 token 维持鉴权;分块 PUT 上传,带续传):
```js
const token = new URLSearchParams(location.search).get('t');
const q = (s) => document.querySelector(s);

// 连 WS 看任务进度
const ws = new WebSocket(`ws://${location.host}/ws?t=${token}`);
const taskMap = {};
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === 'task') { taskMap[msg.data.id] = msg.data; render(); }
};

function fmtSpeed(bps){ if(!bps) return ''; const u=['B','KB','MB','GB']; let i=0,v=bps; while(v>=1024&&i<u.length-1){v/=1024;i++;} return v.toFixed(1)+u[i]+'/s'; }

function render(){
  const ul = q('#tasks'); ul.innerHTML='';
  Object.values(taskMap).forEach(t=>{
    const pct = t.totalBytes? Math.floor(t.transferredBytes/t.totalBytes*100):0;
    const li=document.createElement('li');
    li.innerHTML=`<div>${t.name} <small>${t.status}</small></div>
      <div class="bar"><i style="width:${pct}%"></i></div>
      <div class="meta"><span>${pct}%</span><span>${t.speed?fmtSpeed(t.speed):''}</span></div>`;
    ul.appendChild(li);
  });
}

// 选文件后:先 offer 让电脑端确认,再分块 PUT
q('#sendBtn').onclick = async () => {
  const files = q('#picker').files;
  if(!files.length){ alert('先选文件'); return; }
  const defs = [...files].map((f,i)=>({ id: `m${Date.now()}_${i}`, name: f.name, relPath: f.name, totalBytes: f.size }));
  await fetch(`/api/offer?t=${token}`, { method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({ peer:'手机', files: defs }) });
  // 简化:offer 后直接尝试上传(电脑端 accept 会把状态切到 transferring;
  //       生产可等待 WS 的 accept 事件再传。第一版先轮询 status 容错续传)
  for(let i=0;i<files.length;i++){ await uploadOne(files[i], defs[i].id); }
};

async function uploadOne(file, id){
  // 查询已传偏移(续传)
  let offset = 0;
  try {
    const r = await fetch(`/api/upload/status?id=${id}&t=${token}`);
    if(r.ok){ offset = (await r.json()).offset || 0; }
  } catch(_){}
  const blob = file.slice(offset);
  await fetch(`/api/upload?id=${id}&t=${token}`, {
    method:'PUT',
    headers:{ 'Content-Range': `bytes ${offset}-/${file.size}` },
    body: blob,
  });
}

// 显示主机名
fetch(`/api/health`).then(r=>r.json()).then(d=>{ q('#host').textContent = d.name; });
```
(注:`task.speed` 字段将在 Task 6.1 由后端补充;此处前端已兼容其缺省。)

- [ ] **Step 3: 手动验证(留到 Task 7 整体联调时做)**

本任务先确保 `go build ./...` 通过。
Run: `go build ./...`
Expected: 无报错。

- [ ] **Step 4: 提交**

```bash
git add internal/server/
git commit -m "feat(server): 手机端响应式页面与分块上传"
```

---

## 阶段 6:实时速度统计、mDNS、Wails 装配

### Task 6.1:实时速度统计

**Files:**
- Modify: `internal/transfer/task.go`(加 `Speed` 字段与采样)
- Create: `internal/transfer/speed.go`
- Test: `internal/transfer/speed_test.go`

设计:`SpeedSampler` 周期性对比每个任务的 `Loaded()` 与上次值,算出字节/秒,写入 `Task.Speed`,并 `Touch` 触发 WS 广播与剩余时间计算。

- [ ] **Step 1: 给 Task 加字段**

在 `task.go` 的 `Task` 结构体增加:
```go
	Speed       int64 `json:"speed"`       // 字节/秒(由采样器更新)
	ETASeconds  int64 `json:"etaSeconds"`  // 预计剩余秒数
```

- [ ] **Step 2: 写失败测试**

`internal/transfer/speed_test.go`:
```go
package transfer

import "testing"

func TestComputeSpeed(t *testing.T) {
	// 1 秒内多传了 1MB → 速度约 1MB/s
	sp := computeSpeed(2_000_000, 1_000_000, 1.0)
	if sp != 1_000_000 {
		t.Fatalf("速度应为 1000000,得到 %d", sp)
	}
}

func TestComputeETA(t *testing.T) {
	// 还剩 5MB,速度 1MB/s → 5 秒
	eta := computeETA(10_000_000, 5_000_000, 1_000_000)
	if eta != 5 {
		t.Fatalf("ETA 应为 5,得到 %d", eta)
	}
	// 速度为 0 → ETA 0(未知)
	if computeETA(10, 0, 0) != 0 {
		t.Fatal("速度为 0 时 ETA 应为 0")
	}
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `go test ./internal/transfer/ -run "ComputeSpeed|ComputeETA" -v`
Expected: FAIL,未定义函数。

- [ ] **Step 4: 写实现**

`internal/transfer/speed.go`:
```go
package transfer

import (
	"context"
	"time"
)

// computeSpeed 由两次采样的已传字节与间隔秒数算字节/秒。
func computeSpeed(curr, prev int64, seconds float64) int64 {
	if seconds <= 0 {
		return 0
	}
	d := curr - prev
	if d < 0 {
		d = 0
	}
	return int64(float64(d) / seconds)
}

// computeETA 由总量、已传、速度算剩余秒数;速度为 0 返回 0(未知)。
func computeETA(total, loaded, speed int64) int64 {
	if speed <= 0 {
		return 0
	}
	remain := total - loaded
	if remain < 0 {
		return 0
	}
	return remain / speed
}

// SpeedSampler 周期性更新所有进行中任务的速度与 ETA。
type SpeedSampler struct {
	mgr      *Manager
	interval time.Duration
	last     map[string]int64
}

// NewSpeedSampler 创建采样器,interval 建议 1s。
func NewSpeedSampler(mgr *Manager, interval time.Duration) *SpeedSampler {
	return &SpeedSampler{mgr: mgr, interval: interval, last: make(map[string]int64)}
}

// Run 阻塞运行采样循环,直到 ctx 取消。
func (s *SpeedSampler) Run(ctx context.Context) {
	t := time.NewTicker(s.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			secs := s.interval.Seconds()
			for _, tk := range s.mgr.List() {
				if tk.Status != StatusTransferring {
					continue
				}
				curr := tk.Loaded()
				tk.Speed = computeSpeed(curr, s.last[tk.ID], secs)
				tk.ETASeconds = computeETA(tk.TotalBytes, curr, tk.Speed)
				s.last[tk.ID] = curr
				s.mgr.Touch(tk.ID)
			}
		}
	}
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `go test ./internal/transfer/ -v`
Expected: 全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add internal/transfer/
git commit -m "feat(transfer): 实时速度与剩余时间采样"
```

### Task 6.2:mDNS 发布与发现

**Files:**
- Create: `internal/discovery/mdns.go`
- Test: `internal/discovery/mdns_test.go`

设计:用 `github.com/grandcat/zeroconf`。`Publish` 在局域网注册 `_filetransfer._tcp` 服务(带本机名与端口);`Discover` 在给定超时内列出同网段其他实例。测试只验证发布不报错与发现接口可调用(真实跨机发现靠手动验证)。

- [ ] **Step 1: 加依赖**

Run: `go get github.com/grandcat/zeroconf`
Expected: `go.mod` 出现该依赖。

- [ ] **Step 2: 写失败测试**

`internal/discovery/mdns_test.go`:
```go
package discovery

import (
	"context"
	"testing"
	"time"
)

func TestPublishAndShutdown(t *testing.T) {
	p, err := Publish("test-host", 18080)
	if err != nil {
		t.Skipf("本机 mDNS 环境不可用,跳过: %v", err)
	}
	p.Shutdown()
}

func TestDiscover_ReturnsWithinTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	peers, err := Discover(ctx)
	if err != nil {
		t.Skipf("本机 mDNS 环境不可用,跳过: %v", err)
	}
	// peers 可能为空(没有其他机器),只验证类型与不报错
	_ = peers
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `go test ./internal/discovery/ -v`
Expected: FAIL,未定义 `Publish`/`Discover`。

- [ ] **Step 4: 写实现**

`internal/discovery/mdns.go`:
```go
// Package discovery 用 mDNS 在局域网发布本机并发现其他实例。
package discovery

import (
	"context"

	"github.com/grandcat/zeroconf"
)

const serviceType = "_filetransfer._tcp"

// Peer 是发现到的一个对端实例。
type Peer struct {
	Name string `json:"name"`
	Host string `json:"host"` // IPv4
	Port int    `json:"port"`
}

// Publisher 包装 zeroconf 注册句柄。
type Publisher struct{ srv *zeroconf.Server }

// Publish 在局域网注册本机服务。
func Publish(instance string, port int) (*Publisher, error) {
	srv, err := zeroconf.Register(instance, serviceType, "local.", port, []string{"app=filetransfer"}, nil)
	if err != nil {
		return nil, err
	}
	return &Publisher{srv: srv}, nil
}

// Shutdown 注销服务。
func (p *Publisher) Shutdown() {
	if p.srv != nil {
		p.srv.Shutdown()
	}
}

// Discover 在 ctx 超时内发现同网段其他实例。
func Discover(ctx context.Context) ([]Peer, error) {
	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		return nil, err
	}
	entries := make(chan *zeroconf.ServiceEntry)
	var peers []Peer
	done := make(chan struct{})
	go func() {
		for e := range entries {
			host := ""
			if len(e.AddrIPv4) > 0 {
				host = e.AddrIPv4[0].String()
			}
			peers = append(peers, Peer{Name: e.Instance, Host: host, Port: e.Port})
		}
		close(done)
	}()
	if err := resolver.Browse(ctx, serviceType, "local.", entries); err != nil {
		return nil, err
	}
	<-ctx.Done()
	<-done
	return peers, nil
}
```

- [ ] **Step 5: 跑测试确认通过(或跳过)**

Run: `go test ./internal/discovery/ -v`
Expected: PASS 或 SKIP(本机无 mDNS 环境时跳过,不算失败)。

- [ ] **Step 6: 提交**

```bash
git add internal/discovery/ go.mod go.sum
git commit -m "feat(discovery): mDNS 发布与发现"
```

### Task 6.3:Wails App 绑定与 main 装配

**Files:**
- Modify: `app.go`(替换模板内容,作为桌面前端可调用的门面)
- Modify: `main.go`(装配 server、sampler、mDNS、生命周期)
- Modify: `internal/server/server.go`(暴露 `Start(port)`/`Token()`/`URL(ip,port)` 等辅助)

> 集成性任务,靠 `go build` + 手动联调验证。

- [ ] **Step 1: 给 Server 加启动与辅助方法**

在 `server.go` 追加(import 增加 `"fmt"`、`"net/http"`):
```go
// Token 返回会话令牌。
func (s *Server) Token() string { return s.token }

// Start 在指定端口启动 HTTP 服务(阻塞,通常 go 调用)。
func (s *Server) Start(port int) error {
	return http.ListenAndServe(fmt.Sprintf(":%d", port), s.mux)
}

// MobileURL 拼出手机访问地址(带 token)。
func (s *Server) MobileURL(ip string, port int) string {
	return fmt.Sprintf("http://%s:%d/?t=%s", ip, port, s.token)
}
```

- [ ] **Step 2: 写 App 门面**

`app.go`(整文件替换为):
```go
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"time"

	"filetransfer/internal/discovery"
	"filetransfer/internal/netinfo"
	"filetransfer/internal/qrcode"
	"filetransfer/internal/server"
	"filetransfer/internal/transfer"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App 是 Wails 绑定门面,桌面前端通过它调用后端。
type App struct {
	ctx     context.Context
	mgr     *transfer.Manager
	srv     *server.Server
	ip      string
	port    int
	saveDir string
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
	ip, err := netinfo.LocalIPv4()
	if err == nil {
		a.ip = ip.String()
	}
	a.port, _ = netinfo.FreePort()
	host, _ := os.Hostname()

	a.saveDir = filepath.Join(mustUserDir(), "FileTransferTool")
	_ = os.MkdirAll(a.saveDir, 0o755)

	a.srv = server.New(a.mgr, host, randToken(), a.saveDir)
	// 任务变更 → 推给桌面前端
	a.mgr.OnChange(func(t *transfer.Task) {
		runtime.EventsEmit(a.ctx, "task", t)
	})
	go a.srv.Start(a.port)
	go transfer.NewSpeedSampler(a.mgr, time.Second).Run(ctx)
	if pub, err := discovery.Publish(host, a.port); err == nil {
		_ = pub // 进程退出时随程序释放
	}
}

func mustUserDir() string {
	d, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return filepath.Join(d, "Downloads")
}

// ---- 下面是给前端调用的方法 ----

// MobileQR 返回手机扫码用的二维码 dataURL。
func (a *App) MobileQR() (string, error) {
	return qrcode.DataURL(a.srv.MobileURL(a.ip, a.port), 256)
}

// MobileURL 返回手机访问地址文本(便于手动输入)。
func (a *App) MobileURL() string { return a.srv.MobileURL(a.ip, a.port) }

// Tasks 返回当前所有任务。
func (a *App) Tasks() []*transfer.Task { return a.mgr.List() }

// SetGlobalLimit 设置全局限速(字节/秒,0=不限)。
func (a *App) SetGlobalLimit(bps int) { a.mgr.SetGlobalLimit(bps) }

// SetTaskLimit 设置某任务限速。
func (a *App) SetTaskLimit(id string, bps int) { a.mgr.SetTaskLimit(id, bps) }

// Accept / Reject 接收确认。
func (a *App) Accept(id string) { a.mgr.SetStatus(id, transfer.StatusTransferring, "") }
func (a *App) Reject(id string) { a.mgr.SetStatus(id, transfer.StatusRejected, "") }

// DiscoverPeers 发现局域网内其他电脑(约 1.5s)。
func (a *App) DiscoverPeers() ([]discovery.Peer, error) {
	ctx, cancel := context.WithTimeout(a.ctx, 1500*time.Millisecond)
	defer cancel()
	return discovery.Discover(ctx)
}
```

- [ ] **Step 3: 接 main.go 的 startup**

打开 `main.go`(Wails 模板生成),把创建 App 与 `OnStartup` 接上。模板里一般是:
```go
app := NewApp()
err := wails.Run(&options.App{
	// ...
	OnStartup: app.startup,
	Bind: []interface{}{ app },
})
```
确认 `OnStartup: app.startup` 与 `Bind` 含 `app`。若模板方法名不同(如 `app.startup` 未导出导致无法引用),把 `startup` 改为可被 main 包内引用即可(同包,小写也可访问)。

- [ ] **Step 4: 构建确认**

Run: `go build ./...`
Expected: 无报错(可能需 `go mod tidy` 拉齐依赖)。
Run: `go mod tidy`

- [ ] **Step 5: 提交**

```bash
git add app.go main.go internal/server/server.go go.mod go.sum
git commit -m "feat: Wails App 门面与后端装配"
```

### Task 6.4:桌面窗口前端

**Files:**
- Modify: `frontend/index.html`、`frontend/src/main.js`、`frontend/src/app.css`
- Create: `frontend/src/api.js`

> 手动验证为主。桌面前端通过 Wails 自动生成的 `window.go.main.App.*` 调用后端,并监听 `task` 事件。

- [ ] **Step 1: 写 api 封装**

`frontend/src/api.js`:
```js
// Wails 把 Go 的 App 方法暴露在 window.go.main.App
export const App = () => window.go.main.App;

export async function mobileQR(){ return App().MobileQR(); }
export async function mobileURL(){ return App().MobileURL(); }
export async function tasks(){ return App().Tasks(); }
export function setGlobalLimit(bps){ return App().SetGlobalLimit(bps); }
export function setTaskLimit(id,bps){ return App().SetTaskLimit(id,bps); }
export function accept(id){ return App().Accept(id); }
export function reject(id){ return App().Reject(id); }
export function discoverPeers(){ return App().DiscoverPeers(); }
```

- [ ] **Step 2: 写桌面页面结构**

`frontend/index.html`(body 内容替换为):
```html
<div id="app">
  <aside>
    <h2>扫码连手机</h2>
    <img id="qr" alt="二维码">
    <p id="url" class="url"></p>
    <h2>限速</h2>
    <select id="preset">
      <option value="0">全速</option>
      <option value="10485760">普通 (10MB/s)</option>
      <option value="1048576">省流 (1MB/s)</option>
    </select>
  </aside>
  <main>
    <h2>传输任务</h2>
    <div id="tasks"></div>
    <h2>局域网电脑</h2>
    <button id="scan">扫描</button>
    <ul id="peers"></ul>
  </main>
</div>
<script type="module" src="./src/main.js"></script>
```

- [ ] **Step 3: 写桌面逻辑**

`frontend/src/main.js`:
```js
import './app.css';
import * as api from './api.js';

const q = (s)=>document.querySelector(s);
const fmt = (b)=>{ if(!b) return '0'; const u=['B','KB','MB','GB']; let i=0,v=b; while(v>=1024&&i<3){v/=1024;i++;} return v.toFixed(1)+u[i]; };

async function initQR(){
  q('#qr').src = await api.mobileQR();
  q('#url').textContent = await api.mobileURL();
}

q('#preset').onchange = (e)=> api.setGlobalLimit(parseInt(e.target.value,10));

q('#scan').onclick = async ()=>{
  const peers = await api.discoverPeers();
  q('#peers').innerHTML = peers.map(p=>`<li>${p.name} — ${p.host}:${p.port}</li>`).join('') || '<li>没发现其他电脑</li>';
};

const taskMap = {};
function renderTasks(){
  const box = q('#tasks'); box.innerHTML='';
  Object.values(taskMap).forEach(t=>{
    const pct = t.totalBytes? Math.floor(t.transferredBytes/t.totalBytes*100):0;
    const div = document.createElement('div');
    div.className='task';
    let actions = '';
    if(t.status==='pending' && t.direction==='recv'){
      actions = `<button data-acc="${t.id}">同意</button><button data-rej="${t.id}">拒绝</button>`;
    }
    div.innerHTML = `<div class="row"><b>${t.name}</b><small>${t.status}</small></div>
      <div class="bar"><i style="width:${pct}%"></i></div>
      <div class="meta"><span>${pct}% · ${fmt(t.transferredBytes)}/${fmt(t.totalBytes)}</span>
      <span>${t.speed?fmt(t.speed)+'/s':''} ${t.etaSeconds?('· 约'+t.etaSeconds+'s'):''}</span></div>
      <div class="actions">${actions}
        <input type="number" min="0" placeholder="本任务限速 KB/s" data-lim="${t.id}">
      </div>`;
    box.appendChild(div);
  });
  box.querySelectorAll('[data-acc]').forEach(b=> b.onclick=()=>api.accept(b.dataset.acc));
  box.querySelectorAll('[data-rej]').forEach(b=> b.onclick=()=>api.reject(b.dataset.rej));
  box.querySelectorAll('[data-lim]').forEach(inp=> inp.onchange=()=>{
    api.setTaskLimit(inp.dataset.lim, (parseInt(inp.value,10)||0)*1024);
  });
}

// 监听后端任务事件
window.runtime.EventsOn('task', (t)=>{ taskMap[t.id]=t; renderTasks(); });

initQR();
```
`frontend/src/app.css`:
```css
#app { display:flex; height:100vh; font-family:system-ui,sans-serif; }
aside { width:260px; padding:16px; background:#f0f2f5; overflow:auto; }
main { flex:1; padding:16px; overflow:auto; }
h2 { font-size:15px; margin:14px 0 8px; }
#qr { width:200px; height:200px; background:#fff; border:1px solid #ddd; }
.url { font-size:12px; word-break:break-all; color:#555; }
select, input { width:100%; padding:8px; margin-top:4px; }
.task { border:1px solid #e3e5e8; border-radius:8px; padding:10px; margin-bottom:10px; }
.row { display:flex; justify-content:space-between; }
.bar { height:6px; background:#e6e8eb; border-radius:3px; overflow:hidden; margin:6px 0; }
.bar > i { display:block; height:100%; background:#2d6cdf; }
.meta { font-size:12px; color:#666; display:flex; justify-content:space-between; }
.actions { margin-top:6px; display:flex; gap:6px; align-items:center; }
.actions button { padding:4px 10px; }
```

- [ ] **Step 4: 构建确认**

Run: `wails build` 或先 `cd frontend; npm install; cd ..; wails dev`
Expected: 桌面窗口出现,左侧显示二维码,右侧任务区为空。

- [ ] **Step 5: 提交**

```bash
git add frontend/
git commit -m "feat(frontend): 桌面窗口 UI(二维码/限速/任务/发现)"
```

---

## 阶段 7:整体联调、打包

### Task 7.1:端到端手动联调

**Files:** 无(验证)

- [ ] **Step 1: 启动桌面端**

Run: `wails dev`
Expected: 出窗口,显示二维码与手机访问地址。

- [ ] **Step 2: 手机扫码上传**

手机与电脑连同一 WiFi → 扫二维码 → 打开手机页面 → 选一个文件 → 发送。
Expected: 桌面端"传输任务"出现该任务,进度条走动,显示实时速度;`pending` 时点"同意"后开始;完成后文件出现在 `~/Downloads/FileTransferTool/`。

- [ ] **Step 3: 断点续传验证**

传一个较大文件,中途关掉手机页面再重新扫码进入、重新发送同名文件。
Expected: 从已传偏移继续(查看 `.part` 不从 0 开始),最终文件完整。

- [ ] **Step 4: 限速验证**

把左侧档位切到"省流 (1MB/s)",再传大文件。
Expected: 实时速度被压到约 1MB/s 上下;切回"全速"后速度回升。

- [ ] **Step 5: 完整性校验**

对传输前后的文件比对哈希。
Run(PowerShell):
```powershell
Get-FileHash 源文件路径 -Algorithm SHA256
Get-FileHash "$env:USERPROFILE\Downloads\FileTransferTool\目标文件" -Algorithm SHA256
```
Expected: 两个哈希一致。

- [ ] **Step 6: 电脑↔电脑发现(若有第二台)**

第二台也跑起来,点"扫描"。
Expected: 列出对方实例(名字 + IP:端口)。(跨机传输的发起 UI 属后续增强,本版先验证"发现"。)

### Task 7.2:打包成单 exe

**Files:** 无(产出物)

- [ ] **Step 1: 生产构建**

Run: `wails build -clean`
Expected: `build/bin/filetransfer.exe` 生成。

- [ ] **Step 2: 验证免环境运行**

把 `filetransfer.exe` 拷到另一个目录(模拟"给别人")双击。
Expected: 双击直接出窗口,无需安装 Go/Node;Win10/11 自带 WebView2 时无额外提示。

- [ ] **Step 3: 记录产物说明**

在 `README.md` 写明:双击 exe 出窗口 → 手机连同一 WiFi 扫码 → 传文件;接收文件在"下载/FileTransferTool"。

- [ ] **Step 4: 提交**

```bash
git add build/ README.md
git commit -m "build: 打包单 exe 并补 README"
```

---

## 自检对照(spec 覆盖)

- 电脑↔手机互传:Task 5.x + 7.1 ✅
- 电脑↔电脑发现:Task 6.2 + 7.1 Step6(传输发起为后续增强)✅(发现部分)
- 桌面窗口形态:Task 6.4 ✅
- 手机扫码、不装 App:Task 4.1 + 5.6 + 7.1 ✅
- 限速:档位(6.4)、上限(2.1)、每任务(3.3/6.4)、运行时可调(2.1)✅
- 实时速度/进度/剩余时间:Task 6.1 + 前端 ✅
- 断点续传:Task 3.2 + 5.3/5.4 + 7.1 Step3 ✅
- 整文件夹:RelPath 贯穿(3.1/5.3),前端逐文件带相对路径(5.6 可扩展为 webkitdirectory)⚠️ 第一版手机端为多文件;文件夹选择在桌面端拖拽增强,列为收尾项
- 接收方确认:Task 5.5 + 6.4 ✅
- 单 exe 双击出窗口:Task 0.3 + 7.2 ✅
- 落盘不进 C 盘(Go 装 D 盘):Task 0.1 ✅

> 说明:"整文件夹传"在手机端浏览器需 `webkitdirectory`,第一版手机端先支持多文件多选;桌面端拖文件夹作为阶段 7 之后的小增强。后端按 `RelPath` 重建目录的能力已就位,加前端目录选择即可补齐。
