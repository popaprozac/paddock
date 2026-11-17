package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"syscall"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	nameTimeout = 10 * time.Second // for the guest to send the name it wants
	maxPeek     = 64 << 10         // bytes read looking for that name
	dialTimeout = 30 * time.Second
)

// forwarder carries the guest's TCP connections to ports 80 and 443 out through the host's
// sockets, by name. It reads the name the guest asks for, the TLS server name on 443 and the
// HTTP Host header on 80, checks it against the policy and connects to that name itself, so the
// address the guest connected to never matters. Every other connection is reset.
type forwarder struct {
	policy *policy
	dial   func(ctx context.Context, network, address string) (net.Conn, error)
	logf   func(format string, args ...any)
}

// handle is the netstack's TCP forwarder handler; it runs on its own goroutine.
func (f *forwarder) handle(r *tcp.ForwarderRequest) {
	id := r.ID()
	port := id.LocalPort
	if port != 80 && port != 443 {
		f.logf("deny %s:%d: only ports 80 and 443", id.LocalAddress, port)
		r.Complete(true)
		return
	}
	var wq waiter.Queue
	ep, err := r.CreateEndpoint(&wq)
	r.Complete(false)
	if err != nil {
		return
	}
	guest := gonet.NewTCPConn(&wq, ep)
	defer guest.Close()
	f.serve(guest, id.LocalAddress.String(), port)
}

func (f *forwarder) serve(guest net.Conn, address string, port uint16) {
	_ = guest.SetReadDeadline(time.Now().Add(nameTimeout))
	read := serverName
	if port == 80 {
		read = httpHost
	}
	name, peeked, err := read(io.LimitReader(guest, maxPeek))
	_ = guest.SetReadDeadline(time.Time{})
	if err != nil {
		f.logf("deny %s:%d: %v", address, port, err)
		return
	}
	if !f.policy.allows(name) {
		f.logf("deny %s:%d: not on the list", name, port)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), dialTimeout)
	host, err := f.dial(ctx, "tcp", net.JoinHostPort(name, strconv.Itoa(int(port))))
	cancel()
	if err != nil {
		f.logf("allow %s:%d, but can't connect: %v", name, port, err)
		return
	}
	defer host.Close()
	f.logf("allow %s:%d", name, port)
	if _, err := host.Write(peeked); err == nil {
		splice(guest, host)
	}
}

// serverName reads a TLS ClientHello and returns the server name it asks for, with every byte
// it read, for the caller to pass on.
func serverName(r io.Reader) (string, []byte, error) {
	var read bytes.Buffer
	var hello *tls.ClientHelloInfo
	_ = tls.Server(readOnlyConn{io.TeeReader(r, &read)}, &tls.Config{
		GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			hello = h
			return nil, errors.New("stop after the hello")
		},
	}).Handshake()
	switch {
	case hello == nil:
		return "", nil, errors.New("not a TLS client hello")
	case hello.ServerName == "":
		return "", nil, errors.New("TLS client hello without a server name")
	}
	return hello.ServerName, read.Bytes(), nil
}

// httpHost reads an HTTP request's head and returns the host it is for, without a port, with
// every byte it read, for the caller to pass on.
func httpHost(r io.Reader) (string, []byte, error) {
	var read bytes.Buffer
	request, err := http.ReadRequest(bufio.NewReader(io.TeeReader(r, &read)))
	if err != nil {
		return "", nil, fmt.Errorf("not an HTTP request: %w", err)
	}
	host := request.Host
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	if host == "" {
		return "", nil, errors.New("HTTP request without a host")
	}
	return host, read.Bytes(), nil
}

// readOnlyConn lets crypto/tls parse a ClientHello from a reader. What it writes, an alert after
// the hello is refused, goes nowhere.
type readOnlyConn struct{ io.Reader }

func (readOnlyConn) Write(p []byte) (int, error)      { return len(p), nil }
func (readOnlyConn) Close() error                     { return nil }
func (readOnlyConn) LocalAddr() net.Addr              { return nil }
func (readOnlyConn) RemoteAddr() net.Addr             { return nil }
func (readOnlyConn) SetDeadline(time.Time) error      { return nil }
func (readOnlyConn) SetReadDeadline(time.Time) error  { return nil }
func (readOnlyConn) SetWriteDeadline(time.Time) error { return nil }

// splice copies both ways until both sides have finished sending, passing each side's end of
// sending on to the other.
func splice(a, b net.Conn) {
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(b, a)
		closeWrite(b)
		close(done)
	}()
	_, _ = io.Copy(a, b)
	closeWrite(a)
	<-done
}

func closeWrite(c net.Conn) {
	if half, ok := c.(interface{ CloseWrite() error }); ok {
		_ = half.CloseWrite()
	} else {
		_ = c.Close()
	}
}

// hostDialer connects from the host, refusing loopback and link-local addresses whatever name
// led there: the host's own services, and on EC2 the instance metadata service, stay out of reach.
var hostDialer = &net.Dialer{
	Control: func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		ip := net.ParseIP(host)
		if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
			return fmt.Errorf("%s is the host's own or link-local", host)
		}
		return nil
	},
}
