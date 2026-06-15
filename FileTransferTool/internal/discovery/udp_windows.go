//go:build windows

package discovery

import (
	"net"
	"syscall"
)

// enableBroadcast 给 UDP socket 打开 SO_BROADCAST,否则朝广播地址发包可能被拒。
func enableBroadcast(conn *net.UDPConn) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return
	}
	_ = raw.Control(func(fd uintptr) {
		_ = syscall.SetsockoptInt(syscall.Handle(fd), syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1)
	})
}
