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
