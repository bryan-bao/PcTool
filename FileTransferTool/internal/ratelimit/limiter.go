// Package ratelimit 提供可运行时调整的令牌桶限速器,以及限速的 io.Reader。
package ratelimit

import (
	"context"
	"io"
	"sync"

	"golang.org/x/time/rate"
)

// Limiter 包装令牌桶。bytesPerSec <= 0 表示不限速。线程安全。
type Limiter struct {
	mu      sync.Mutex
	lim     *rate.Limiter
	limited bool
}

// New 创建限速器。bytesPerSec <= 0 为不限速。
func New(bytesPerSec int) *Limiter {
	l := &Limiter{}
	l.SetLimit(bytesPerSec)
	return l
}

// SetLimit 运行时调整速率上限(字节/秒)。<=0 表示不限速,立即生效。
func (l *Limiter) SetLimit(bytesPerSec int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if bytesPerSec <= 0 {
		l.limited = false
		l.lim = nil
		return
	}
	l.limited = true
	// 突发容量压到最多 64KB(一个读块),让限速立即平滑生效、避免头部"冲一下";
	// 稳态速率仍为 bytesPerSec,不影响整体吞吐。
	burst := bytesPerSec
	if burst > 64*1024 {
		burst = 64 * 1024
	}
	l.lim = rate.NewLimiter(rate.Limit(bytesPerSec), burst)
}

// WaitN 阻塞直到可消费 n 字节配额;不限速时立即返回。
func (l *Limiter) WaitN(ctx context.Context, n int) error {
	l.mu.Lock()
	lim := l.lim
	limited := l.limited
	l.mu.Unlock()
	if !limited || n <= 0 {
		return nil
	}
	// rate.Limiter 不允许单次 WaitN 超过桶容量,按容量分批申请。
	burst := lim.Burst()
	for n > 0 {
		step := n
		if step > burst {
			step = burst
		}
		if err := lim.WaitN(ctx, step); err != nil {
			return err
		}
		n -= step
	}
	return nil
}

// LimitedReader 在读取时对全局闸和任务闸同时计量。
type LimitedReader struct {
	r      io.Reader
	global *Limiter // 全局总闸,可为 nil
	task   *Limiter // 任务闸,可为 nil
	ctx    context.Context
}

// NewLimitedReader 包装 r。global/task 任一可为 nil(表示该级不限)。
func NewLimitedReader(r io.Reader, task *Limiter, global *Limiter) *LimitedReader {
	return &LimitedReader{r: r, task: task, global: global, ctx: context.Background()}
}

// WithContext 设置取消用的 context(用于中止传输)。
func (lr *LimitedReader) WithContext(ctx context.Context) *LimitedReader {
	lr.ctx = ctx
	return lr
}

func (lr *LimitedReader) Read(p []byte) (int, error) {
	n, err := lr.r.Read(p)
	if n > 0 {
		if lr.global != nil {
			if werr := lr.global.WaitN(lr.ctx, n); werr != nil {
				return n, werr
			}
		}
		if lr.task != nil {
			if werr := lr.task.WaitN(lr.ctx, n); werr != nil {
				return n, werr
			}
		}
	}
	return n, err
}
