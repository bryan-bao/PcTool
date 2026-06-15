// Package discovery 用 mDNS 在局域网发布本机并发现其他实例。
package discovery

import (
	"context"

	"github.com/grandcat/zeroconf"
)

const serviceType = "_filetransfer._tcp"

// Peer 是发现到的一个对端实例。
type Peer struct {
	Name string `json:"name"`
	Host string `json:"host"` // IPv4
	Port int    `json:"port"`
}

// Publisher 包装 zeroconf 注册句柄。
type Publisher struct{ srv *zeroconf.Server }

// Publish 在局域网注册本机服务。
func Publish(instance string, port int) (*Publisher, error) {
	srv, err := zeroconf.Register(instance, serviceType, "local.", port, []string{"app=filetransfer"}, nil)
	if err != nil {
		return nil, err
	}
	return &Publisher{srv: srv}, nil
}

// Shutdown 注销服务。
func (p *Publisher) Shutdown() {
	if p.srv != nil {
		p.srv.Shutdown()
	}
}

// Discover 在 ctx 超时内发现同网段其他实例。
func Discover(ctx context.Context) ([]Peer, error) {
	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		return nil, err
	}
	entries := make(chan *zeroconf.ServiceEntry)
	var peers []Peer
	done := make(chan struct{})
	go func() {
		for e := range entries {
			host := ""
			if len(e.AddrIPv4) > 0 {
				host = e.AddrIPv4[0].String()
			}
			peers = append(peers, Peer{Name: e.Instance, Host: host, Port: e.Port})
		}
		close(done)
	}()
	if err := resolver.Browse(ctx, serviceType, "local.", entries); err != nil {
		return nil, err
	}
	<-ctx.Done()
	<-done
	return peers, nil
}
