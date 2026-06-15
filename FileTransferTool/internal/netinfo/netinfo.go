// Package netinfo 提供本机局域网网络信息:私有 IPv4 与可用端口。
package netinfo

import (
	"errors"
	"fmt"
	"net"
)

// LocalIPv4 返回本机第一个非回环的私有 IPv4 地址(供手机/其他电脑连接)。
func LocalIPv4() (net.IP, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP.To4()
			if ip != nil && ip.IsPrivate() {
				return ip, nil
			}
		}
	}
	return nil, errors.New("未找到局域网 IPv4 地址,请检查是否连上了 WiFi/网线")
}

// LocalIPv4Set 返回本机所有启用网卡的 IPv4 集合(含 Tailscale、回环),
// 用于扫描结果里"排除自己"。
func LocalIPv4Set() map[string]bool {
	set := map[string]bool{"127.0.0.1": true}
	ifaces, err := net.Interfaces()
	if err != nil {
		return set
	}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok {
				if ip := ipnet.IP.To4(); ip != nil {
					set[ip.String()] = true
				}
			}
		}
	}
	return set
}

// tailscaleNet 是 Tailscale 分配地址所用的 CGNAT 网段(100.64.0.0/10)。
var tailscaleNet = func() *net.IPNet {
	_, n, _ := net.ParseCIDR("100.64.0.0/10")
	return n
}()

// TailscaleIPv4 返回本机 Tailscale 虚拟网卡的 IPv4(100.x.x.x);没装或没登录则报错。
func TailscaleIPv4() (net.IP, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP.To4()
			if ip != nil && tailscaleNet.Contains(ip) {
				return ip, nil
			}
		}
	}
	return nil, errors.New("未找到 Tailscale 地址(可能没装或没登录)")
}

// FreePort 让系统分配一个当前空闲的 TCP 端口并返回其号码。
func FreePort() (int, error) {
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// PreferredOrFreePort 优先尝试占用 preferred 端口(空闲就用它,方便远程时固定地址);
// 若被占用,则退回到系统随机分配一个空闲端口。
func PreferredOrFreePort(preferred int) int {
	l, err := net.Listen("tcp", fmt.Sprintf(":%d", preferred))
	if err == nil {
		l.Close()
		return preferred
	}
	p, _ := FreePort()
	return p
}
