package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// clientHello returns the bytes a TLS client sends first when it asks for serverName.
func clientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	client, server := net.Pipe()
	defer server.Close()
	go func() {
		_ = tls.Client(client, &tls.Config{ServerName: serverName}).Handshake()
		client.Close()
	}()
	_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
	header := make([]byte, 5)
	if _, err := io.ReadFull(server, header); err != nil {
		t.Fatal(err)
	}
	body := make([]byte, int(header[3])<<8|int(header[4]))
	if _, err := io.ReadFull(server, body); err != nil {
		t.Fatal(err)
	}
	return append(header, body...)
}

func TestServerNameReadsTheTLSHelloAndKeepsItsBytes(t *testing.T) {
	hello := clientHello(t, "github.com")
	name, peeked, err := serverName(bytes.NewReader(hello))
	if err != nil || name != "github.com" {
		t.Fatalf("got %q, %v; want github.com", name, err)
	}
	if !bytes.Equal(peeked, hello) {
		t.Errorf("kept %d bytes, want the hello's %d", len(peeked), len(hello))
	}
}

func TestServerNameRefusesWhatIsNotATLSHello(t *testing.T) {
	if _, _, err := serverName(strings.NewReader("GET / HTTP/1.1\r\nHost: github.com\r\n\r\n")); err == nil {
		t.Error("took an HTTP request for a TLS hello")
	}
}

func TestHTTPHostReadsTheHostWithoutItsPort(t *testing.T) {
	request := "GET /x HTTP/1.1\r\nHost: GitHub.com:80\r\nUser-Agent: t\r\n\r\nbody"
	name, peeked, err := httpHost(strings.NewReader(request))
	if err != nil || name != "GitHub.com" {
		t.Fatalf("got %q, %v; want GitHub.com", name, err)
	}
	if !strings.HasPrefix(request, string(peeked)) || !strings.Contains(string(peeked), "\r\n\r\n") {
		t.Errorf("kept %q, want the request's head", peeked)
	}
}

func TestHTTPHostRefusesARequestWithoutAHost(t *testing.T) {
	if _, _, err := httpHost(strings.NewReader("GET / HTTP/1.0\r\n\r\n")); err == nil {
		t.Error("took a request without a host")
	}
}

// forwardOnce runs one guest connection through a forwarder whose dial records the address and
// answers with a pipe that echoes "pong" after reading what was passed on. It returns what the
// forwarder logged, too.
func forwardOnce(t *testing.T, list string, port uint16, send []byte) (dialed string, got []byte, logged []string) {
	t.Helper()
	p, err := parsePolicy(list)
	if err != nil {
		t.Fatal(err)
	}
	f := &forwarder{
		policy: holding(p),
		logf: func(format string, args ...any) {
			logged = append(logged, fmt.Sprintf(format, args...))
			t.Logf(format, args...)
		},
		dial: func(_ context.Context, _, address string) (net.Conn, error) {
			dialed = address
			ours, theirs := net.Pipe()
			go func() {
				buf := make([]byte, len(send))
				_, _ = io.ReadFull(theirs, buf)
				_, _ = theirs.Write([]byte("pong"))
				theirs.Close()
			}()
			return ours, nil
		},
	}
	guest, ours := net.Pipe()
	done := make(chan struct{})
	go func() {
		f.serve(ours, "203.0.113.9", port)
		ours.Close()
		close(done)
	}()
	_ = guest.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := guest.Write(send); err != nil {
		t.Fatal(err)
	}
	got, _ = io.ReadAll(guest)
	guest.Close()
	<-done
	return dialed, got, logged
}

func TestForwarderConnectsToTheAllowedNameNotTheAddress(t *testing.T) {
	dialed, got, _ := forwardOnce(t, "github.com", 443, clientHello(t, "github.com"))
	if dialed != "github.com:443" || string(got) != "pong" {
		t.Errorf("dialed %q and got %q; want github.com:443 and pong", dialed, got)
	}
	dialed, got, _ = forwardOnce(t, "github.com", 80, []byte("GET / HTTP/1.1\r\nHost: github.com\r\n\r\n"))
	if dialed != "github.com:80" || string(got) != "pong" {
		t.Errorf("HTTP: dialed %q and got %q; want github.com:80 and pong", dialed, got)
	}
}

func TestForwarderClosesNamesNotOnTheList(t *testing.T) {
	dialed, got, _ := forwardOnce(t, "github.com", 443, clientHello(t, "attacker.example"))
	if dialed != "" || len(got) != 0 {
		t.Errorf("dialed %q and got %q; want neither", dialed, got)
	}
}

// The forwarder checks, logs and connects to one spelling of the name the guest asks for.
func TestForwarderChecksAndConnectsToTheSameName(t *testing.T) {
	dialed, got, _ := forwardOnce(t, "github.com", 80, []byte("GET / HTTP/1.1\r\nHost: GitHub.COM.\r\n\r\n"))
	if dialed != "github.com:80" || string(got) != "pong" {
		t.Errorf("dialed %q and got %q; want github.com:80 and pong", dialed, got)
	}
	// A dotted capital I lowercases to github.com in Unicode, and a line break would start a
	// log line of its own.
	for _, name := range []string{"gİthub.com", "github.com\n2026/11/22 12:00:00 paddock-net: allow github.com:443"} {
		dialed, got, logged := forwardOnce(t, "github.com", 443, clientHello(t, name))
		if dialed != "" || len(got) != 0 || len(logged) != 1 || strings.Contains(logged[0], "\n") ||
			!strings.HasSuffix(logged[0], "not a host name") {
			t.Errorf("%q: dialed %q, got %q, logged %q; want a refusal on one line", name, dialed, got, logged)
		}
	}
}

func TestHostDialerRefusesTheHostsOwnAddresses(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	for _, address := range []string{listener.Addr().String(), "169.254.169.254:80"} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		conn, err := hostDialer.DialContext(ctx, "tcp", address)
		cancel()
		if err == nil {
			conn.Close()
			t.Errorf("connected to %s", address)
		} else if errors.Is(err, context.DeadlineExceeded) {
			t.Errorf("%s: timed out instead of refusing", address)
		}
	}
}
