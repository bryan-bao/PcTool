package server

import (
	"archive/zip"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"filetransfer/internal/ratelimit"
	"filetransfer/internal/transfer"
)

// handleUpload 接收上传文件体,落盘到 .part 并支持断点续传;读取时套两级限速。
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	tk, ok := s.mgr.Get(id)
	if !ok {
		http.Error(w, "未知任务", http.StatusNotFound)
		return
	}
	dest := filepath.Join(s.SaveDir(), filepath.FromSlash(tk.RelPath))
	f, off, err := transfer.OpenForResume(dest)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	tk.SetTransferred(off)

	// 接收方向也套两级限速(限制对方上传占用本机带宽)。
	reader := ratelimit.NewLimitedReader(r.Body, s.mgr.TaskLimiter(id), s.mgr.GlobalLimiter()).
		WithContext(r.Context())

	buf := make([]byte, 64*1024)
	var copyErr error
	for {
		n, rerr := reader.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				copyErr = werr
				break
			}
			tk.AddTransferred(int64(n))
			s.mgr.Touch(id)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			copyErr = rerr
			break
		}
	}
	// 必须先关闭文件,Windows 下才能把 .part 改名为最终文件。
	f.Close()

	if copyErr != nil {
		// 写盘或网络中断:标记可续传,不算彻底失败。
		s.mgr.SetStatus(id, transfer.StatusPaused, copyErr.Error())
		http.Error(w, copyErr.Error(), http.StatusBadGateway)
		return
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

// handleUploadStatus 返回某任务已落盘的偏移(供客户端续传前查询)。
func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	tk, ok := s.mgr.Get(id)
	if !ok {
		http.Error(w, "未知任务", http.StatusNotFound)
		return
	}
	dest := filepath.Join(s.SaveDir(), filepath.FromSlash(tk.RelPath))
	off, err := transfer.ResumeOffset(dest)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"offset": off})
}

// RegisterSendFile 登记某 send 任务对应的本地源文件路径。
func (s *Server) RegisterSendFile(taskID, absPath string) {
	s.sendMu.Lock()
	s.sendFiles[taskID] = absPath
	s.sendMu.Unlock()
}

// handleDownload 发送本地文件给请求方,支持 Range 续传与两级限速。
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

// ---- 文件分享页:加进来的文件/文件夹共用一个 /s/{id} 网页链接,可增可删 ----

// randShareID 生成不可猜的分享 id(16 位十六进制),它本身就是链接的"钥匙"。
func randShareID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// shareItem 是分享里的一个条目:单个文件,或整个文件夹(下载时打包成 zip)。
type shareItem struct {
	id    string // 条目 id,下载路径 /s/{shareID}/{id}
	name  string // 文件名或文件夹名
	path  string // 本地绝对路径
	isDir bool
	size  int64 // 文件大小;文件夹为内部所有文件之和
	count int   // 内含文件数(文件为 1)
}

// ShareEntry 是给桌面前端看的分享条目。
type ShareEntry struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
	Count int    `json:"count"`
}

// ShareAdd 把一批本地文件/文件夹加进分享(shareID 传空则新建),返回分享 id。
// 同一路径重复添加会被跳过;文件夹按一个条目算,不展开。
func (s *Server) ShareAdd(shareID string, paths []string) (string, error) {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if shareID == "" {
		shareID = randShareID()
	}
	items := s.shares[shareID]
	exists := make(map[string]bool, len(items))
	for _, it := range items {
		exists[it.path] = true
	}
	for _, p := range paths {
		if exists[p] {
			continue
		}
		fi, err := os.Stat(p)
		if err != nil {
			continue // 读不到的跳过
		}
		it := shareItem{id: randShareID(), name: filepath.Base(p), path: p, isDir: fi.IsDir()}
		if fi.IsDir() {
			it.size, it.count = dirStats(p)
		} else {
			it.size, it.count = fi.Size(), 1
		}
		items = append(items, it)
		exists[p] = true
	}
	if len(items) == 0 {
		return "", fmt.Errorf("没有可分享的文件")
	}
	s.shares[shareID] = items
	return shareID, nil
}

// ShareRemove 从分享里移除一个条目。
func (s *Server) ShareRemove(shareID, entryID string) {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	items := s.shares[shareID]
	for i, it := range items {
		if it.id == entryID {
			s.shares[shareID] = append(items[:i], items[i+1:]...)
			return
		}
	}
}

// ShareEntries 列出分享里的条目(给桌面前端渲染列表)。
func (s *Server) ShareEntries(shareID string) []ShareEntry {
	s.sendMu.RLock()
	defer s.sendMu.RUnlock()
	items := s.shares[shareID]
	out := make([]ShareEntry, 0, len(items))
	for _, it := range items {
		out = append(out, ShareEntry{ID: it.id, Name: it.name, IsDir: it.isDir, Size: it.size, Count: it.count})
	}
	return out
}

// dirStats 统计文件夹内(含子目录)文件总大小与个数。
func dirStats(root string) (int64, int) {
	var size int64
	var count int
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if info, err := d.Info(); err == nil {
			size += info.Size()
			count++
		}
		return nil
	})
	return size, count
}

// handleShare 分发 /s/ 下的两类请求:
//   - /s/{id}        分享页(HTML,列出所有文件)
//   - /s/{id}/{fid}  下载页内某个文件
func (s *Server) handleShare(w http.ResponseWriter, r *http.Request) {
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/s/"), "/")
	parts := strings.SplitN(rest, "/", 2)
	s.sendMu.RLock()
	items, ok := s.shares[parts[0]]
	s.sendMu.RUnlock()
	if !ok {
		http.Error(w, "链接不存在或已失效(发送方可能重启了程序)", http.StatusNotFound)
		return
	}
	if len(parts) == 1 {
		s.renderSharePage(w, parts[0], items)
		return
	}
	for _, it := range items {
		if it.id == parts[1] {
			if it.isDir {
				s.serveShareDir(w, r, it)
			} else {
				s.serveShareFile(w, r, it)
			}
			return
		}
	}
	http.Error(w, "文件不存在", http.StatusNotFound)
}

// renderSharePage 渲染分享页:文件按名字+大小列出,文件夹只显示文件夹本身(不展开)。
func (s *Server) renderSharePage(w http.ResponseWriter, shareID string, items []shareItem) {
	type row struct{ Icon, Name, SizeText, Href, Btn string }
	rows := make([]row, 0, len(items))
	for _, it := range items {
		rw := row{
			Icon: "📄", Name: it.name, SizeText: fmtBytes(it.size),
			Href: fmt.Sprintf("/s/%s/%s", shareID, it.id), Btn: "下载",
		}
		if it.isDir {
			rw.Icon, rw.Btn = "📁", "打包下载"
			rw.SizeText = fmt.Sprintf("%d 个文件 · %s", it.count, fmtBytes(it.size))
		}
		rows = append(rows, rw)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = sharePageTpl.Execute(w, map[string]any{"HostName": s.hostName, "Files": rows})
}

// fmtBytes 把字节数变成人看的 KB/MB/GB。
func fmtBytes(n int64) string {
	const k = 1024
	switch {
	case n >= k*k*k:
		return fmt.Sprintf("%.1f GB", float64(n)/(k*k*k))
	case n >= k*k:
		return fmt.Sprintf("%.1f MB", float64(n)/(k*k))
	case n >= k:
		return fmt.Sprintf("%.1f KB", float64(n)/k)
	}
	return fmt.Sprintf("%d B", n)
}

// serveShareFile 把分享的文件发给请求方,浏览器点击即弹下载。
// 支持 Range 续传与两级限速;每次下载记一个发送任务,窗口里能看到进度。
func (s *Server) serveShareFile(w http.ResponseWriter, r *http.Request, it shareItem) {
	f, err := os.Open(it.path)
	if err != nil {
		http.Error(w, "文件已不存在: "+err.Error(), http.StatusNotFound)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	total := fi.Size()
	name := it.name

	start, _ := parseRangeStart(r.Header.Get("Range"))
	if start > 0 {
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			http.Error(w, err.Error(), http.StatusRequestedRangeNotSatisfiable)
			return
		}
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	// filename* 用 UTF-8 编码,中文文件名也能正确保存
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="%s"; filename*=UTF-8''%s`, name, url.PathEscape(name)))
	w.Header().Set("Accept-Ranges", "bytes")
	if start > 0 {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, total-1, total))
		w.Header().Set("Content-Length", strconv.FormatInt(total-start, 10))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
	}

	// 每次下载记一个发送任务,窗口里能看到谁在下、下到哪了。
	tid := randShareID()
	tk := s.mgr.Add(&transfer.Task{
		ID: tid, Name: name, RelPath: name, TotalBytes: total,
		Direction: transfer.DirSend, Status: transfer.StatusTransferring, Peer: r.RemoteAddr,
	})
	tk.SetTransferred(start)

	reader := ratelimit.NewLimitedReader(f, s.mgr.TaskLimiter(tid), s.mgr.GlobalLimiter()).
		WithContext(r.Context())
	buf := make([]byte, 64*1024)
	for {
		n, rerr := reader.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				s.mgr.SetStatus(tid, transfer.StatusFailed, "对方中断了下载")
				return
			}
			tk.AddTransferred(int64(n))
			s.mgr.Touch(tid)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			s.mgr.SetStatus(tid, transfer.StatusFailed, rerr.Error())
			return
		}
	}
	s.mgr.SetStatus(tid, transfer.StatusDone, "")
}

// serveShareDir 把整个文件夹打包成 zip 流式发给请求方。
// 用 Store(不压缩):CPU 省、进度跟文件总大小对得上;同样走两级限速并记任务。
func (s *Server) serveShareDir(w http.ResponseWriter, r *http.Request, it shareItem) {
	zipName := it.name + ".zip"
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="%s"; filename*=UTF-8''%s`, zipName, url.PathEscape(zipName)))

	tid := randShareID()
	tk := s.mgr.Add(&transfer.Task{
		ID: tid, Name: zipName, RelPath: zipName, TotalBytes: it.size,
		Direction: transfer.DirSend, Status: transfer.StatusTransferring, Peer: r.RemoteAddr,
	})

	zw := zip.NewWriter(w)
	walkErr := filepath.WalkDir(it.path, func(fp string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(it.path, fp)
		if err != nil {
			return nil
		}
		f, err := os.Open(fp)
		if err != nil {
			return nil // 个别打不开的跳过,不影响整包
		}
		defer f.Close()
		entry, err := zw.CreateHeader(&zip.FileHeader{
			Name:   filepath.ToSlash(filepath.Join(it.name, rel)), // zip 内带文件夹名前缀
			Method: zip.Store,
		})
		if err != nil {
			return err
		}
		reader := ratelimit.NewLimitedReader(f, s.mgr.TaskLimiter(tid), s.mgr.GlobalLimiter()).
			WithContext(r.Context())
		buf := make([]byte, 64*1024)
		for {
			n, rerr := reader.Read(buf)
			if n > 0 {
				if _, werr := entry.Write(buf[:n]); werr != nil {
					return werr
				}
				tk.AddTransferred(int64(n))
				s.mgr.Touch(tid)
			}
			if rerr == io.EOF {
				return nil
			}
			if rerr != nil {
				return rerr
			}
		}
	})
	closeErr := zw.Close()
	if walkErr != nil || closeErr != nil {
		s.mgr.SetStatus(tid, transfer.StatusFailed, "打包下载中断")
		return
	}
	s.mgr.SetStatus(tid, transfer.StatusDone, "")
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

// handleOffer 接收发送方的文件清单,建出 pending 任务并经 WS 通知接收端弹窗。
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
