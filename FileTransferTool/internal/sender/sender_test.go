package sender

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"filetransfer/internal/server"
	"filetransfer/internal/transfer"
)

// TestSendFile_DeliversToReceiver 真实地把本地文件经 HTTP 发给一个真实的接收 server,
// 验证对端收到的文件内容(哈希)一致 —— 这就是电脑↔电脑互传的核心链路。
func TestSendFile_DeliversToReceiver(t *testing.T) {
	recvDir := t.TempDir()
	mgr := transfer.NewManager(0)
	srv := server.New(mgr, "recv", "tok", recvDir)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// 造源文件
	srcDir := t.TempDir()
	src := filepath.Join(srcDir, "hello.txt")
	content := []byte("hello from PC A —— 电脑互传")
	if err := os.WriteFile(src, content, 0o644); err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256(content)

	tk := &transfer.Task{ID: "s1", Name: "hello.txt", RelPath: "hello.txt", Direction: transfer.DirSend, Status: transfer.StatusTransferring}
	if err := SendFile(ts.URL, "PC-A", tk, src, nil, nil, nil); err != nil {
		t.Fatalf("发送失败: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(recvDir, "hello.txt"))
	if err != nil {
		t.Fatalf("对端应收到文件: %v", err)
	}
	gotSum := sha256.Sum256(got)
	if hex.EncodeToString(gotSum[:]) != hex.EncodeToString(want[:]) {
		t.Fatalf("内容哈希不一致: 收到 %q", got)
	}
	if tk.Loaded() != int64(len(content)) {
		t.Fatalf("发送进度应为 %d,得到 %d", len(content), tk.Loaded())
	}
}

// TestSendFile_ResumesFromPartial 验证:对端已有部分数据时,发送端只补发剩余。
func TestSendFile_ResumesFromPartial(t *testing.T) {
	recvDir := t.TempDir()
	mgr := transfer.NewManager(0)
	srv := server.New(mgr, "recv", "tok", recvDir)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	full := []byte("0123456789ABCDEF")
	// 预置对端已收到前 6 字节的 .part
	if err := os.WriteFile(filepath.Join(recvDir, "f.bin.part"), full[:6], 0o644); err != nil {
		t.Fatal(err)
	}
	// 对端需要有这个任务记录(handleUploadStatus 要查 task 的 relPath)
	mgr.Add(&transfer.Task{ID: "s2", Name: "f.bin", RelPath: "f.bin", TotalBytes: int64(len(full)), Direction: transfer.DirRecv, Status: transfer.StatusTransferring})

	srcDir := t.TempDir()
	src := filepath.Join(srcDir, "f.bin")
	if err := os.WriteFile(src, full, 0o644); err != nil {
		t.Fatal(err)
	}

	tk := &transfer.Task{ID: "s2", Name: "f.bin", RelPath: "f.bin", Direction: transfer.DirSend, Status: transfer.StatusTransferring}
	if err := SendFile(ts.URL, "PC-A", tk, src, nil, nil, nil); err != nil {
		t.Fatalf("发送失败: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(recvDir, "f.bin"))
	if err != nil {
		t.Fatalf("对端应收到完整文件: %v", err)
	}
	if string(got) != string(full) {
		t.Fatalf("续传后内容不对: %q", got)
	}
}
