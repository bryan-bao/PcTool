package netinfo

import (
	"net"
	"testing"
)

func TestLocalIPv4_ReturnsPrivateAddress(t *testing.T) {
	ip, err := LocalIPv4()
	if err != nil {
		t.Skipf("本机未连入局域网,跳过: %v", err)
	}
	if ip == nil || ip.To4() == nil {
		t.Fatalf("期望一个 IPv4 地址,得到: %v", ip)
	}
	if !ip.IsPrivate() {
		t.Fatalf("期望局域网私有地址(192.168/10/172.16-31),得到: %v", ip)
	}
}

func TestFreePort_IsUsable(t *testing.T) {
	port, err := FreePort()
	if err != nil {
		t.Fatalf("FreePort 报错: %v", err)
	}
	if port <= 0 || port > 65535 {
		t.Fatalf("端口越界: %d", port)
	}
}

func TestPreferredOrFreePort_UsesPreferredWhenFree(t *testing.T) {
	// 先拿一个空闲端口当作 preferred,它此刻是空的,应被原样返回
	pref, _ := FreePort()
	got := PreferredOrFreePort(pref)
	if got != pref {
		t.Fatalf("preferred 端口空闲时应返回它本身,期望 %d,得到 %d", pref, got)
	}
}

func TestPreferredOrFreePort_FallsBackWhenBusy(t *testing.T) {
	// 占住一个端口,再把它作为 preferred,应退回到别的空闲端口
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	busy := l.Addr().(*net.TCPAddr).Port
	got := PreferredOrFreePort(busy)
	if got == busy {
		t.Fatalf("preferred 端口被占用时不应返回它,得到 %d", got)
	}
	if got <= 0 || got > 65535 {
		t.Fatalf("退回的端口越界: %d", got)
	}
}
