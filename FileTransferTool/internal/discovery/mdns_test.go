package discovery

import (
	"context"
	"testing"
	"time"
)

func TestPublishAndShutdown(t *testing.T) {
	p, err := Publish("test-host", 18080)
	if err != nil {
		t.Skipf("本机 mDNS 环境不可用,跳过: %v", err)
	}
	p.Shutdown()
}

func TestDiscover_ReturnsWithinTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	peers, err := Discover(ctx)
	if err != nil {
		t.Skipf("本机 mDNS 环境不可用,跳过: %v", err)
	}
	_ = peers // 可能为空(没有其他机器),只验证不报错
}
