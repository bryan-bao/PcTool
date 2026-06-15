// Package server 提供局域网内置 HTTP/WS 服务,供手机浏览器与其他电脑收发文件。
package server

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"strings"
	"sync"

	"filetransfer/internal/transfer"
)

//go:embed web/*
var webFS embed.FS

// sharePageTpl 是分享页模板(对方浏览器打开 /s/{id} 看到的文件列表)。
var sharePageTpl = template.Must(template.ParseFS(webFS, "web/share.html"))

// Server 持有依赖并装配路由。
type Server struct {
	mgr       *transfer.Manager
	hostName  string
	token     string // 会话级一次性令牌
	saveDir   string // 接收文件保存目录
	mux       *http.ServeMux
	hub       *hub
	sendFiles map[string]string      // taskID -> 本地源文件绝对路径(下载方向)
	shares    map[string][]shareItem // shareID -> 一组分享文件(分享页 /s/{id})
	sendMu    sync.RWMutex
	saveMu    sync.RWMutex // 保护 saveDir(可运行时更改)
}

// SaveDir 返回当前接收文件保存目录(并发安全)。
func (s *Server) SaveDir() string {
	s.saveMu.RLock()
	defer s.saveMu.RUnlock()
	return s.saveDir
}

// SetSaveDir 运行时更改接收文件保存目录。
func (s *Server) SetSaveDir(dir string) {
	s.saveMu.Lock()
	s.saveDir = dir
	s.saveMu.Unlock()
}

// New 创建服务。saveDir 为接收文件落盘根目录。
func New(mgr *transfer.Manager, hostName, token, saveDir string) *Server {
	s := &Server{
		mgr: mgr, hostName: hostName, token: token, saveDir: saveDir,
		mux: http.NewServeMux(), hub: newHub(),
		sendFiles: make(map[string]string),
		shares:    make(map[string][]shareItem),
	}
	// 任务变更 → 广播给所有 WS 客户端(手机/其他电脑实时进度)
	s.mgr.OnChange(func(t *transfer.Task) {
		s.hub.broadcast("task", t)
	})
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux.HandleFunc("/api/health", s.handleHealth)
	s.mux.HandleFunc("/api/upload", s.handleUpload)
	s.mux.HandleFunc("/api/upload/status", s.handleUploadStatus)
	s.mux.HandleFunc("/api/download", s.handleDownload)
	s.mux.HandleFunc("/api/offer", s.handleOffer)
	s.mux.HandleFunc("/api/offer/", s.handleOfferAction) // /api/offer/{id}/accept|reject
	s.mux.HandleFunc("/s/", s.handleShare) // 分享页:/s/{id} 列文件,/s/{id}/{fid} 下载
	s.mux.HandleFunc("/ws", s.handleWS)
	s.mux.HandleFunc("/", s.requireToken(s.handleStatic))
}

// Handler 返回顶层 http.Handler(便于测试)。
func (s *Server) Handler() http.Handler { return s.mux }

// Token 返回会话令牌。
func (s *Server) Token() string { return s.token }

// Start 在指定端口启动 HTTP 服务(阻塞,通常 go 调用)。
func (s *Server) Start(port int) error {
	return http.ListenAndServe(fmt.Sprintf(":%d", port), s.logged(s.mux))
}

// logged 是日志中间件:把每个进来的请求打到日志(控制台 + 日志文件)。
// 注意:不包装 ResponseWriter,以免破坏 WebSocket 升级所需的 Hijacker。
func (s *Server) logged(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("[HTTP] %s %s (来自 %s)", r.Method, r.URL.RequestURI(), r.RemoteAddr)
		h.ServeHTTP(w, r)
	})
}

// MobileURL 拼出手机访问地址(带 token)。
func (s *Server) MobileURL(ip string, port int) string {
	return fmt.Sprintf("http://%s:%d/?t=%s", ip, port, s.token)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "name": s.hostName})
}

// requireToken 是中间件:校验连接码。
// 首页用网址里的 ?t=<token> 握手,成功后种下会话 cookie;
// 之后浏览器请求 mobile.js/css 等子资源虽然不带查询参数,但会自动带上 cookie,凭此放行。
func (s *Server) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("t") == s.token {
			http.SetCookie(w, &http.Cookie{
				Name: "ft_token", Value: s.token, Path: "/", HttpOnly: true,
			})
			next(w, r)
			return
		}
		if c, err := r.Cookie("ft_token"); err == nil && c.Value == s.token {
			next(w, r)
			return
		}
		http.Error(w, "无效或缺失的连接码", http.StatusUnauthorized)
	}
}

// handleStatic 提供手机端静态资源(html/css/js),受 token 中间件保护。
func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	if name == "" {
		name = "mobile.html"
	}
	data, err := fs.ReadFile(webFS, "web/"+name)
	if err != nil {
		http.Error(w, "404 not found", http.StatusNotFound)
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

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
