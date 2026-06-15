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

// handleWS 升级为 WebSocket,连上先发当前任务快照,之后持续接收广播。
func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	s.hub.add(c)
	defer s.hub.remove(c)
	for _, t := range s.mgr.List() {
		_ = c.WriteJSON(map[string]any{"type": "task", "data": t})
	}
	for {
		if _, _, err := c.ReadMessage(); err != nil {
			return
		}
	}
}
