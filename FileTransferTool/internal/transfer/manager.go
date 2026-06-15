package transfer

import (
	"sync"

	"filetransfer/internal/ratelimit"
)

// ChangeFunc 任务变更回调(用于把进度/状态推给 UI)。
type ChangeFunc func(*Task)

// Manager 管理全部传输任务与限速器,并发安全。
type Manager struct {
	mu       sync.RWMutex
	tasks    map[string]*Task
	taskLims map[string]*ratelimit.Limiter
	global   *ratelimit.Limiter
	onChange []ChangeFunc
}

// NewManager 创建管理器,globalBps 为全局限速(0=不限)。
func NewManager(globalBps int) *Manager {
	return &Manager{
		tasks:    make(map[string]*Task),
		taskLims: make(map[string]*ratelimit.Limiter),
		global:   ratelimit.New(globalBps),
	}
}

// Add 加入任务并返回它(同时为其建一个任务级限速器)。
func (m *Manager) Add(t *Task) *Task {
	m.mu.Lock()
	m.tasks[t.ID] = t
	m.taskLims[t.ID] = ratelimit.New(t.LimitBytesPerSec)
	m.mu.Unlock()
	m.fire(t)
	return t
}

// Get 取任务。
func (m *Manager) Get(id string) (*Task, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	t, ok := m.tasks[id]
	return t, ok
}

// List 返回所有任务的快照切片。
func (m *Manager) List() []*Task {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]*Task, 0, len(m.tasks))
	for _, t := range m.tasks {
		out = append(out, t)
	}
	return out
}

// GlobalLimiter 返回全局限速器。
func (m *Manager) GlobalLimiter() *ratelimit.Limiter { return m.global }

// SetGlobalLimit 运行时调整全局限速(字节/秒,0=不限)。
func (m *Manager) SetGlobalLimit(bps int) { m.global.SetLimit(bps) }

// TaskLimiter 返回某任务的限速器(不存在则 nil)。
func (m *Manager) TaskLimiter(id string) *ratelimit.Limiter {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.taskLims[id]
}

// SetTaskLimit 运行时调整某任务限速。
func (m *Manager) SetTaskLimit(id string, bps int) {
	m.mu.Lock()
	if t, ok := m.tasks[id]; ok {
		t.LimitBytesPerSec = bps
	}
	if l, ok := m.taskLims[id]; ok {
		l.SetLimit(bps)
	}
	t := m.tasks[id]
	m.mu.Unlock()
	if t != nil {
		m.fire(t)
	}
}

// SetStatus 改状态并触发回调。
func (m *Manager) SetStatus(id string, s Status, errMsg string) {
	m.mu.Lock()
	t, ok := m.tasks[id]
	if ok {
		t.Status = s
		if errMsg != "" {
			t.Err = errMsg
		}
	}
	m.mu.Unlock()
	if ok {
		m.fire(t)
	}
}

// Touch 主动触发一次变更回调(用于进度推送)。
func (m *Manager) Touch(id string) {
	if t, ok := m.Get(id); ok {
		m.fire(t)
	}
}

// OnChange 注册任务变更回调。
func (m *Manager) OnChange(fn ChangeFunc) {
	m.mu.Lock()
	m.onChange = append(m.onChange, fn)
	m.mu.Unlock()
}

func (m *Manager) fire(t *Task) {
	m.mu.RLock()
	cbs := make([]ChangeFunc, len(m.onChange))
	copy(cbs, m.onChange)
	m.mu.RUnlock()
	for _, fn := range cbs {
		fn(t)
	}
}
