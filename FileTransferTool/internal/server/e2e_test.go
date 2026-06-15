package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"filetransfer/internal/transfer"
)

// TestE2E_UploadResumeAndIntegrity 模拟手机端完整上传:
// offer → accept → 分两段(中断后续传)上传 1MB → 校验 SHA256 一致。
func TestE2E_UploadResumeAndIntegrity(t *testing.T) {
	dir := t.TempDir()
	mgr := transfer.NewManager(0)
	s := New(mgr, "host", "tok", dir)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	// 造 1MB 可重现数据并算源哈希
	data := make([]byte, 1<<20)
	for i := range data {
		data[i] = byte(i * 7)
	}
	srcSum := sha256.Sum256(data)
	srcHash := hex.EncodeToString(srcSum[:])

	id := "f1"
	// 1) offer
	offerBody := fmt.Sprintf(`{"peer":"phone","files":[{"id":"%s","name":"big.bin","relPath":"big.bin","totalBytes":%d}]}`, id, len(data))
	if resp, err := http.Post(ts.URL+"/api/offer", "application/json", bytes.NewBufferString(offerBody)); err != nil {
		t.Fatal(err)
	} else {
		resp.Body.Close()
	}
	// 2) accept
	if resp, err := http.Post(ts.URL+"/api/offer/"+id+"/accept", "", nil); err != nil {
		t.Fatal(err)
	} else {
		resp.Body.Close()
	}

	put := func(start int, chunk []byte) {
		req, _ := http.NewRequest("PUT", ts.URL+"/api/upload?id="+id, bytes.NewReader(chunk))
		req.Header.Set("Content-Range", fmt.Sprintf("bytes %d-/%d", start, len(data)))
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, r.Body)
		r.Body.Close()
	}

	// 3) 第一段:上传前 600KB(模拟中断)
	put(0, data[:600*1024])
	// 4) 查询续传偏移
	r, err := http.Get(ts.URL + "/api/upload/status?id=" + id)
	if err != nil {
		t.Fatal(err)
	}
	var st struct {
		Offset int64 `json:"offset"`
	}
	json.NewDecoder(r.Body).Decode(&st)
	r.Body.Close()
	if st.Offset != 600*1024 {
		t.Fatalf("续传偏移应为 614400,得到 %d", st.Offset)
	}
	// 5) 第二段:从偏移续传剩余
	put(int(st.Offset), data[st.Offset:])

	// 6) 校验最终文件哈希
	got, err := os.ReadFile(filepath.Join(dir, "big.bin"))
	if err != nil {
		t.Fatalf("最终文件应存在: %v", err)
	}
	gotSum := sha256.Sum256(got)
	if hex.EncodeToString(gotSum[:]) != srcHash {
		t.Fatal("哈希不一致,文件在传输中损坏了")
	}
}

// TestE2E_RateLimit 验证全局限速真实生效(512KB/s 传 512KB 应耗时 ≥0.5s)。
func TestE2E_RateLimit(t *testing.T) {
	dir := t.TempDir()
	mgr := transfer.NewManager(0)
	mgr.SetGlobalLimit(512 * 1024) // 512KB/s
	s := New(mgr, "host", "tok", dir)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	data := make([]byte, 512*1024)
	id := "f2"
	mgr.Add(&transfer.Task{ID: id, Name: "r.bin", RelPath: "r.bin", TotalBytes: int64(len(data)), Direction: transfer.DirRecv, Status: transfer.StatusTransferring})

	start := time.Now()
	req, _ := http.NewRequest("PUT", ts.URL+"/api/upload?id="+id, bytes.NewReader(data))
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, r.Body)
	r.Body.Close()
	elapsed := time.Since(start)
	if elapsed < 500*time.Millisecond {
		t.Fatalf("限速 512KB/s 传 0.5MB 应耗时 ≥0.5s,实际 %v(限速可能没生效)", elapsed)
	}
}
