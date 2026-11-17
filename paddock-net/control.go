package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// serveControl listens at path, a Unix socket only this user can open, for new lists from
// paddock. Each connection carries one line of JSON, {"allow":["github.com","*.example.org"]},
// and gets {} back once the list is in force, or {"error":"..."} with the old list kept.
// Connections already open stay open; the new list applies to what the guest does next.
func serveControl(path string, current *atomic.Pointer[policy], logf func(string, ...any)) error {
	_ = os.Remove(path) // left by a paddock-net that was killed
	old := syscall.Umask(0o177)
	listener, err := net.Listen("unix", path)
	syscall.Umask(old)
	if err != nil {
		return err
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handleControl(conn, current, logf)
		}
	}()
	return nil
}

func handleControl(conn net.Conn, current *atomic.Pointer[policy], logf func(string, ...any)) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	var answer struct {
		Error string `json:"error,omitempty"`
	}
	var request struct {
		Allow []string `json:"allow"`
	}
	line, _ := bufio.NewReader(io.LimitReader(conn, 64<<10)).ReadBytes('\n')
	if err := json.Unmarshal(line, &request); err != nil {
		answer.Error = "unreadable request: " + err.Error()
	} else if p, err := newPolicy(request.Allow); err != nil {
		answer.Error = err.Error()
	} else {
		current.Store(p)
		list := strings.Join(request.Allow, ", ")
		if list == "" {
			list = "nothing"
		}
		logf("now allowing %s", list)
	}
	reply, _ := json.Marshal(answer)
	_, _ = conn.Write(append(reply, '\n'))
}
