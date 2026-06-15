package server

import (
	"archive/zip"
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
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

func TestDownload_FullAndRange(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "send.bin")
	if err := os.WriteFile(src, []byte("ABCDEFGHIJ"), 0o644); err != nil {
		t.Fatal(err)
	}
	mgr := transfer.NewManager(0)
	mgr.Add(&transfer.Task{ID: "d1", Name: "send.bin", TotalBytes: 10, Direction: transfer.DirSend, Status: transfer.StatusTransferring})
	s := New(mgr, "host", "tok123", dir)
	s.RegisterSendFile("d1", src)

	req := httptest.NewRequest("GET", "/api/download?id=d1", nil)
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	if rec.Body.String() != "ABCDEFGHIJ" {
		t.Fatalf("全量内容不对: %q", rec.Body.String())
	}
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

func TestShare_AddRemovePageAndZip(t *testing.T) {
	dir := t.TempDir()
	// 一个散文件 + 一个带子目录的文件夹
	file := filepath.Join(dir, "单文件.bin")
	if err := os.WriteFile(file, []byte("ABCDEFGHIJ"), 0o644); err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(dir, "资料")
	if err := os.MkdirAll(filepath.Join(folder, "子目录"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "子目录", "深处.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	mgr := transfer.NewManager(0)
	s := New(mgr, "host", "tok123", dir)
	id, err := s.ShareAdd("", []string{file, folder})
	if err != nil {
		t.Fatal(err)
	}
	entries := s.ShareEntries(id)
	if len(entries) != 2 || entries[1].IsDir != true || entries[1].Count != 1 || entries[1].Size != 5 {
		t.Fatalf("应 2 个条目且文件夹统计正确,得到 %+v", entries)
	}

	// 重复添加同一路径不产生重复条目;追加进的还是同一个分享 id
	id2, _ := s.ShareAdd(id, []string{file})
	if id2 != id || len(s.ShareEntries(id)) != 2 {
		t.Fatalf("重复添加应去重且共用同一分享: id2=%s n=%d", id2, len(s.ShareEntries(id)))
	}

	// 分享页:列出文件名和文件夹名,但不展开文件夹内部
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/s/"+id, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("分享页应 200,得到 %d", rec.Code)
	}
	page := rec.Body.String()
	if !strings.Contains(page, "单文件.bin") || !strings.Contains(page, "资料") {
		t.Fatalf("分享页应列出两个条目,得到: %s", page)
	}
	if strings.Contains(page, "深处.txt") {
		t.Fatalf("文件夹不应展开内部文件: %s", page)
	}

	// 页面应有两个下载链接(顺序与条目一致:文件在前、文件夹在后)
	hrefs := regexp.MustCompile(`href="(/s/[a-f0-9]+/[a-f0-9]+)"`).FindAllStringSubmatch(page, -1)
	if len(hrefs) != 2 {
		t.Fatalf("应有 2 个下载链接,得到 %d", len(hrefs))
	}

	// 文件:全量 + Range 续传
	rec2 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec2, httptest.NewRequest("GET", hrefs[0][1], nil))
	if rec2.Code != http.StatusOK || rec2.Body.String() != "ABCDEFGHIJ" {
		t.Fatalf("全量下载不对: %d %q", rec2.Code, rec2.Body.String())
	}
	req3 := httptest.NewRequest("GET", hrefs[0][1], nil)
	req3.Header.Set("Range", "bytes=4-")
	rec3 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec3, req3)
	if rec3.Code != http.StatusPartialContent || rec3.Body.String() != "EFGHIJ" {
		t.Fatalf("Range 下载不对: %d %q", rec3.Code, rec3.Body.String())
	}

	// 文件夹:打包成 zip,里面带相对路径
	rec4 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec4, httptest.NewRequest("GET", hrefs[1][1], nil))
	if rec4.Code != http.StatusOK || rec4.Header().Get("Content-Type") != "application/zip" {
		t.Fatalf("文件夹应打包成 zip: %d %s", rec4.Code, rec4.Header().Get("Content-Type"))
	}
	zr, err := zip.NewReader(bytes.NewReader(rec4.Body.Bytes()), int64(rec4.Body.Len()))
	if err != nil {
		t.Fatalf("zip 解析失败: %v", err)
	}
	if len(zr.File) != 1 || zr.File[0].Name != "资料/子目录/深处.txt" {
		t.Fatalf("zip 内容不对: %+v", zr.File)
	}
	zf, _ := zr.File[0].Open()
	got, _ := io.ReadAll(zf)
	zf.Close()
	if string(got) != "hello" {
		t.Fatalf("zip 内文件内容不对: %q", got)
	}

	// 删除文件条目后,分享页不再显示它
	s.ShareRemove(id, entries[0].ID)
	rec5 := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec5, httptest.NewRequest("GET", "/s/"+id, nil))
	if strings.Contains(rec5.Body.String(), "单文件.bin") {
		t.Fatalf("删除后不应再列出: %s", rec5.Body.String())
	}

	// 乱猜的分享 id / 条目 id 必须 404
	for _, p := range []string{"/s/notexist", "/s/" + id + "/notexist"} {
		recX := httptest.NewRecorder()
		s.Handler().ServeHTTP(recX, httptest.NewRequest("GET", p, nil))
		if recX.Code != http.StatusNotFound {
			t.Fatalf("%s 应 404,得到 %d", p, recX.Code)
		}
	}
}

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
