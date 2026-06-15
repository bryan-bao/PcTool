package transfer

import (
	"context"
	"time"
)

// computeSpeed 由两次采样的已传字节与间隔秒数算字节/秒。
func computeSpeed(curr, prev int64, seconds float64) int64 {
	if seconds <= 0 {
		return 0
	}
	d := curr - prev
	if d < 0 {
		d = 0
	}
	return int64(float64(d) / seconds)
}

// computeETA 由总量、已传、速度算剩余秒数;速度为 0 返回 0(未知)。
func computeETA(total, loaded, speed int64) int64 {
	if speed <= 0 {
		return 0
	}
	remain := total - loaded
	if remain < 0 {
		return 0
	}
	return remain / speed
}

// SpeedSampler 周期性更新所有进行中任务的速度与 ETA。
type SpeedSampler struct {
	mgr      *Manager
	interval time.Duration
	last     map[string]int64
}

// NewSpeedSampler 创建采样器,interval 建议 1s。
func NewSpeedSampler(mgr *Manager, interval time.Duration) *SpeedSampler {
	return &SpeedSampler{mgr: mgr, interval: interval, last: make(map[string]int64)}
}

// Run 阻塞运行采样循环,直到 ctx 取消。
func (s *SpeedSampler) Run(ctx context.Context) {
	t := time.NewTicker(s.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			secs := s.interval.Seconds()
			for _, tk := range s.mgr.List() {
				if tk.Status != StatusTransferring {
					continue
				}
				curr := tk.Loaded()
				tk.Speed = computeSpeed(curr, s.last[tk.ID], secs)
				tk.ETASeconds = computeETA(tk.TotalBytes, curr, tk.Speed)
				s.last[tk.ID] = curr
				s.mgr.Touch(tk.ID)
			}
		}
	}
}
