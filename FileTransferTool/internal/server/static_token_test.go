package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"filetransfer/internal/transfer"
)

// TestStaticAssets_LoadAfterTokenHandshake 复现并锁定 bug:
// 手机用带 token 的网址打开首页后,浏览器请求 mobile.js/css 时是相对路径、不带 token。
// 期望:首页握手时种下会话 cookie,后续子资源凭 cookie 放行(200)。
func TestStaticAssets_LoadAfterTokenHandshake(t *testing.T) {
	s := New(transfer.NewManager(0), "h", "tok123", ".")

	// 1) 带 token 访问首页,应 200 并种下会话 cookie
	req := httptest.NewRequest("GET", "/?t=tok123", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("首页应 200,得到 %d", rec.Code)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("首页握手应种下会话 cookie(否则子资源无法带凭证)")
	}

	// 2) 浏览器随后请求 mobile.js,不带 token 查询,但带上 cookie,应 200
	req2 := httptest.NewRequest("GET", "/mobile.js", nil)
	for _, c := range cookies {
		req2.AddCookie(c)
	}
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("mobile.js 带会话 cookie 应 200,得到 %d", rec2.Code)
	}
}

// TestStaticAssets_NoCredential_Rejected 确认:既无 token 也无 cookie,仍应 401。
func TestStaticAssets_NoCredential_Rejected(t *testing.T) {
	s := New(transfer.NewManager(0), "h", "tok123", ".")
	req := httptest.NewRequest("GET", "/mobile.js", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("无任何凭证应 401,得到 %d", rec.Code)
	}
}
