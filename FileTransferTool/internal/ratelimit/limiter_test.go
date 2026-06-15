package ratelimit

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestLimiter_Unlimited_NoDelay(t *testing.T) {
	l := New(0) // 0 = 不限速
	start := time.Now()
	if err := l.WaitN(context.Background(), 10_000_000); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("不限速时不应有明显等待")
	}
}

func TestLimiter_CapsThroughput(t *testing.T) {
	// 限 1MB/s,读 ~256KB,至少需要约 0.25s。给宽松下限避免抖动。
	l := New(1 << 20)
	src := strings.NewReader(strings.Repeat("x", 256*1024))
	r := NewLimitedReader(src, l, nil)
	buf := make([]byte, 32*1024)
	start := time.Now()
	total := 0
	for {
		n, err := r.Read(buf)
		total += n
		if err != nil {
			break
		}
	}
	elapsed := time.Since(start)
	if total != 256*1024 {
		t.Fatalf("读取字节数不对: %d", total)
	}
	if elapsed < 150*time.Millisecond {
		t.Fatalf("限速未生效,用时过短: %v", elapsed)
	}
}

func TestLimiter_SetLimit_Runtime(t *testing.T) {
	l := New(1 << 20)
	l.SetLimit(0) // 运行中改成不限速
	start := time.Now()
	if err := l.WaitN(context.Background(), 5_000_000); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("改成不限速后不应等待")
	}
}
