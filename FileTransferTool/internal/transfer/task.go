// Package transfer 定义传输任务模型、状态机、断点续传与任务管理。
package transfer

import "sync/atomic"

// Status 是任务状态。
type Status string

const (
	StatusPending      Status = "pending"      // 等接收方确认
	StatusTransferring Status = "transferring" // 传输中
	StatusPaused       Status = "paused"       // 已暂停(可续传)
	StatusDone         Status = "done"         // 已完成
	StatusFailed       Status = "failed"       // 失败
	StatusRejected     Status = "rejected"     // 被接收方拒绝
)

// Direction 表示方向(相对本机)。
type Direction string

const (
	DirSend Direction = "send" // 本机发出
	DirRecv Direction = "recv" // 本机接收
)

// Task 一个文件的传输任务。TransferredBytes 用原子操作以便进度协程读取。
type Task struct {
	ID               string    `json:"id"`
	Name             string    `json:"name"`    // 显示名(文件名)
	RelPath          string    `json:"relPath"` // 相对路径(文件夹传输时重建目录用)
	TotalBytes       int64     `json:"totalBytes"`
	TransferredBytes int64     `json:"transferredBytes"`
	Status           Status    `json:"status"`
	Direction        Direction `json:"direction"`
	Peer             string    `json:"peer"`     // 对端名字/地址
	LimitBytesPerSec int       `json:"limitBps"` // 本任务限速,0=不限
	Speed            int64     `json:"speed"`    // 字节/秒(由采样器更新)
	ETASeconds       int64     `json:"etaSeconds"`
	Err              string    `json:"err,omitempty"`
}

// SetTransferred 原子设置已传字节。
func (t *Task) SetTransferred(n int64) { atomic.StoreInt64(&t.TransferredBytes, n) }

// AddTransferred 原子累加并返回新值。
func (t *Task) AddTransferred(n int64) int64 { return atomic.AddInt64(&t.TransferredBytes, n) }

// Loaded 原子读取已传字节。
func (t *Task) Loaded() int64 { return atomic.LoadInt64(&t.TransferredBytes) }

// Progress 返回 0~1 的进度。
func (t *Task) Progress() float64 {
	if t.TotalBytes <= 0 {
		return 0
	}
	return float64(t.Loaded()) / float64(t.TotalBytes)
}

// CanResume 是否可续传:未完成且已传 < 总量。
func (t *Task) CanResume() bool {
	if t.Status == StatusDone || t.Status == StatusRejected {
		return false
	}
	return t.Loaded() < t.TotalBytes
}
