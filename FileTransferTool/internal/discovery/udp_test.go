package discovery

import (
	"net"
	"testing"
	"time"
)

// TestUDPDiscover_RoundTrip 验证 UDP 探测协议:应答器在线时,扫描方能拿到名字和端口。
func TestUDPDiscover_RoundTrip(t *testing.T) {
	r, err := startResponderOn(0, "测试机", 5252) // 0 = 随机端口,避开正在运行的程序
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	port := r.conn.LocalAddr().(*net.UDPAddr).Port

	peers, err := discoverUDP([]net.IP{net.ParseIP("127.0.0.1")}, port, 800*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if len(peers) != 1 {
		t.Fatalf("应发现 1 台,得到 %d", len(peers))
	}
	if peers[0].Name != "测试机" || peers[0].Port != 5252 || peers[0].Host != "127.0.0.1" {
		t.Fatalf("应答内容不对: %+v", peers[0])
	}
}

// TestUDPDiscover_IgnoreJunk 乱七八糟的包不应被当成应答。
func TestUDPDiscover_IgnoreJunk(t *testing.T) {
	// 起一个只会回垃圾数据的"假应答器"
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	port := conn.LocalAddr().(*net.UDPAddr).Port
	go func() {
		buf := make([]byte, 256)
		for {
			_, raddr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			_, _ = conn.WriteToUDP([]byte("随便什么垃圾数据"), raddr)
		}
	}()

	peers, err := discoverUDP([]net.IP{net.ParseIP("127.0.0.1")}, port, 500*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if len(peers) != 0 {
		t.Fatalf("垃圾应答不应入列,得到 %+v", peers)
	}
}
