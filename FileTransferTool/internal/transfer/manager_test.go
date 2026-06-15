package transfer

import "testing"

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
