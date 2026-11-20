package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// testAgent runs commands as the test's own user, without a login shell, in a folder of its own.
func testAgent(t *testing.T) *agent {
	return &agent{files: t.TempDir() + "/paddock", shell: []string{"/bin/sh", "-c"},
		setClock: func(time.Time) error { return errors.New("no clock in tests") }}
}

// pair is a connected pair of sockets, as a vsock connection is in the guest.
func pair(t *testing.T) (client, server *net.UnixConn) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	wrap := func(fd int) *net.UnixConn {
		f := os.NewFile(uintptr(fd), "pair")
		defer f.Close()
		c, err := net.FileConn(f)
		if err != nil {
			t.Fatal(err)
		}
		return c.(*net.UnixConn)
	}
	return wrap(fds[0]), wrap(fds[1])
}

// ask sends a request line and `data` to the agent and returns all it answers. With `hold`, the
// client keeps its side open after sending, as a stalled host would.
func ask(t *testing.T, a *agent, line string, data []byte, hold bool) []byte {
	t.Helper()
	client, server := pair(t)
	defer client.Close()
	go a.serve(server)
	go func() {
		client.Write(append([]byte(line+"\n"), data...))
		if !hold {
			client.CloseWrite()
		}
	}()
	answer, err := io.ReadAll(client)
	if err != nil {
		t.Fatal(err)
	}
	return answer
}

func lines(answer []byte) []string {
	return strings.Split(strings.TrimSuffix(string(answer), "\n"), "\n")
}

func TestHealthAnswersTheVersion(t *testing.T) {
	got := lines(ask(t, testAgent(t), `{"op":"health"}`, nil, false))
	if want := []string{`{"version":"0.1.0"}`}; strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestRefusesWhatItCantAnswer(t *testing.T) {
	for request, want := range map[string]string{
		`nonsense`:         "unreadable request",
		`{"command":"ls"}`: "unreadable request",
		`{"op":"reboot"}`:  "unknown request 'reboot'",
		`{"op":"run"}`:     "run needs a command",
		`{"op":"run","command":"true","as":"bob"}`:  "run as 'root' or as the workload account, not 'bob'",
		`{"op":"put","name":".hidden","size":1}`:    "put needs a plain file name and a size up to 4294967296 bytes",
		`{"op":"put","name":"a/b","size":1}`:        "put needs a plain file name and a size up to 4294967296 bytes",
		`{"op":"put","name":"a","size":-1}`:         "put needs a plain file name and a size up to 4294967296 bytes",
		`{"op":"put","name":"a","size":4294967297}`: "put needs a plain file name and a size up to 4294967296 bytes",
		`{"op":"put","name":"a"}`:                   "put needs a plain file name and a size up to 4294967296 bytes",
		`{"op":"get","name":"../etc/passwd"}`:       "get needs a plain file name",
		`{"op":"get","name":"missing"}`:             "can't read 'missing' in the guest",
		`{"op":"clock"}`:                            "clock needs a time",
	} {
		got := lines(ask(t, testAgent(t), request, nil, false))
		if len(got) != 1 || got[0] != `{"error":"`+want+`"}` {
			t.Errorf("%s: got %q, want error %q", request, got, want)
		}
	}
}

func TestRunStreamsCombinedOutputThenTheExitStatus(t *testing.T) {
	got := lines(ask(t, testAgent(t), `{"op":"run","command":"echo one; echo two >&2; echo; printf tail; exit 3"}`, nil, false))
	want := []string{`{"output":"one"}`, `{"output":"two"}`, `{"output":""}`, `{"output":"tail"}`, `{"exit":3}`}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestRunSplitsLinesOver8KB(t *testing.T) {
	got := lines(ask(t, testAgent(t), `{"op":"run","command":"head -c 20000 /dev/zero | tr '\\0' a; echo"}`, nil, false))
	var sizes []int
	for _, line := range got[:len(got)-1] {
		var r response
		if json.Unmarshal([]byte(line), &r) != nil || r.Output == nil {
			t.Fatalf("not an output line: %q", line)
		}
		sizes = append(sizes, len(*r.Output))
	}
	if len(sizes) != 3 || sizes[0] != 8192 || sizes[1] != 8192 || sizes[2] != 3616 || got[len(got)-1] != `{"exit":0}` {
		t.Fatalf("got line sizes %v and last %q", sizes, got[len(got)-1])
	}
}

func TestPutThenGetGivesBackTheSameBytes(t *testing.T) {
	a := testAgent(t)
	data := make([]byte, 3<<20+5) // more than one chunk
	rand.Read(data)
	if got := string(ask(t, a, `{"op":"put","name":"bundle","size":3145733}`, data, false)); got != "{\"exit\":0}\n" {
		t.Fatalf("put answered %q", got)
	}
	if info, err := os.Stat(a.files + "/bundle"); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("stored file: %v, %v", info, err)
	}

	answer := bufio.NewReader(bytes.NewReader(ask(t, a, `{"op":"get","name":"bundle"}`, nil, false)))
	var back []byte
	for {
		line, err := answer.ReadBytes('\n')
		if err != nil {
			t.Fatalf("get ended without an exit line after %d bytes", len(back))
		}
		var r response
		if json.Unmarshal(line, &r) != nil {
			t.Fatalf("unreadable line %q", line)
		}
		if r.Exit != nil {
			break
		}
		if r.Chunk == nil || *r.Chunk < 1 || *r.Chunk > fileChunk {
			t.Fatalf("unexpected line %q", line)
		}
		chunk := make([]byte, *r.Chunk)
		if _, err := io.ReadFull(answer, chunk); err != nil {
			t.Fatal(err)
		}
		back = append(back, chunk...)
	}
	if !bytes.Equal(back, data) {
		t.Fatalf("got back %d bytes that differ from the %d put", len(back), len(data))
	}
}

func TestPutSaysHowFarAShortUploadGot(t *testing.T) {
	got := string(ask(t, testAgent(t), `{"op":"put","name":"a","size":10}`, []byte("abcd"), false))
	if want := "{\"error\":\"'a' stopped after 4 of 10 bytes\"}\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestPutGivesUpOnAClientThatStopsSending(t *testing.T) {
	defer func(was time.Duration) { idle = was }(idle)
	idle = 100 * time.Millisecond
	got := string(ask(t, testAgent(t), `{"op":"put","name":"a","size":10}`, []byte("abcd"), true))
	if want := "{\"error\":\"'a' stopped after 4 of 10 bytes\"}\n"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestClockSetsTheTimeTheHostSends(t *testing.T) {
	a := testAgent(t)
	var set time.Time
	a.setClock = func(t time.Time) error { set = t; return nil }
	if got := string(ask(t, a, `{"op":"clock","time":1763664000123456789}`, nil, false)); got != "{\"exit\":0}\n" {
		t.Fatalf("clock answered %q", got)
	}
	if set.UnixNano() != 1763664000123456789 {
		t.Fatalf("set the clock to %v", set)
	}
}

func TestIPv4NameserversLeavesOutLoopbackAndIPv6(t *testing.T) {
	got := ipv4Nameservers("# from DHCP\nnameserver 127.0.0.53\nnameserver 192.168.64.1\nnameserver fe80::1\nsearch .\nnameserver\n")
	if len(got) != 1 || got[0] != "192.168.64.1" {
		t.Fatalf("got %q", got)
	}
}
