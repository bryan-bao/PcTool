package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"filetransfer/internal/transfer"
)

func newTestServer() *Server {
	return New(transfer.NewManager(0), "test-host", "tok123", ".")
}

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

func TestRoot_RequiresToken(t *testing.T) {
	s := newTestServer()
	req := httptest.NewRequest("GET", "/", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("无 token 应 401,得到 %d", rec.Code)
	}
	req2 := httptest.NewRequest("GET", "/?t=tok123", nil)
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("带正确 token 应 200,得到 %d", rec2.Code)
	}
}
