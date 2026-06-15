package discovery

import (
	"bytes"
	"encoding/json"
	"net"
	"time"
)

// UDP 广播发现:mDNS 在 Windows 多网卡(虚拟网卡/Tailscale)环境下经常抽风,
// 这里加一条自家协议兜底——扫描方朝网段广播一句"谁在",在线实例直接回包。
const (
	udpPort     = 52719 // 探测端口(主服务端口 52718 + 1)
	probeMagic  = "FT_DISCOVER_V1"
	replyPrefix = "FT_HERE_V1|"
)

// Responder 监听 UDP 探测广播并应答本机信息(每个实例启动时开一个)。
type Responder struct{ conn *net.UDPConn }

// StartResponder 在固定探测端口起应答器。name/port 是回给对方的本机名和服务端口。
func StartResponder(name string, port int) (*Responder, error) {
	return startResponderOn(udpPort, name, port)
}

func startResponderOn(listenPort int, name string, port int) (*Responder, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: listenPort})
	if err != nil {
		return nil, err
	}
	r := &Responder{conn: conn}
	go r.loop(name, port)
	return r, nil
}

func (r *Responder) loop(name string, port int) {
	reply, _ := json.Marshal(Peer{Name: name, Port: port})
	reply = append([]byte(replyPrefix), reply...)
	buf := make([]byte, 256)
	for {
		n, raddr, err := r.conn.ReadFromUDP(buf)
		if err != nil {
			return // conn 已关闭
		}
		if string(buf[:n]) == probeMagic {
			_, _ = r.conn.WriteToUDP(reply, raddr)
		}
	}
}

// Close 停止应答。
func (r *Responder) Close() {
	if r.conn != nil {
		_ = r.conn.Close()
	}
}

// DiscoverUDP 朝所有网卡的广播地址发探测,收集 timeout 内的应答。
func DiscoverUDP(timeout time.Duration) ([]Peer, error) {
	return discoverUDP(broadcastAddrs(), udpPort, timeout)
}

func discoverUDP(dsts []net.IP, port int, timeout time.Duration) ([]Peer, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	enableBroadcast(conn)

	send := func() {
		for _, dst := range dsts {
			_, _ = conn.WriteToUDP([]byte(probeMagic), &net.UDPAddr{IP: dst, Port: port})
		}
	}
	send()
	// UDP 可能丢包,中途补发一次
	resend := time.AfterFunc(timeout/3, send)
	defer resend.Stop()

	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	var peers []Peer
	seen := make(map[string]bool) // 补发探测会让同一台回两次包,按来源去重
	buf := make([]byte, 1024)
	for {
		n, raddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			break // 超时收工
		}
		if !bytes.HasPrefix(buf[:n], []byte(replyPrefix)) {
			continue
		}
		var p Peer
		if json.Unmarshal(buf[len(replyPrefix):n], &p) != nil {
			continue
		}
		p.Host = raddr.IP.String() // 地址以实际回包来源为准
		key := raddr.String()
		if seen[key] {
			continue
		}
		seen[key] = true
		peers = append(peers, p)
	}
	return peers, nil
}

// broadcastAddrs 列出所有启用网卡的子网广播地址,外加全网广播。
func broadcastAddrs() []net.IP {
	out := []net.IP{net.IPv4bcast}
	ifaces, err := net.Interfaces()
	if err != nil {
		return out
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
			if ip == nil || !ip.IsPrivate() {
				continue
			}
			// 子网广播 = IP | ^mask
			bc := make(net.IP, 4)
			for i := 0; i < 4; i++ {
				bc[i] = ip[i] | ^ipnet.Mask[i]
			}
			out = append(out, bc)
		}
	}
	return out
}
