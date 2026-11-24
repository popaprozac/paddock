package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"sync/atomic"
)

// serveControl reads new lists from paddock on conn until paddock closes it. Each is one line of
// JSON, {"allow":["github.com","*.example.org"]}, and gets {} back once it is in force, or
// {"error":"..."} with the old list kept. Connections the guest already has open stay open; the
// new list applies to what it does next.
func serveControl(conn net.Conn, current *atomic.Pointer[policy], logf func(string, ...any)) {
	defer conn.Close()
	lines := bufio.NewReaderSize(conn, 64<<10)
	for {
		// A line over 64 KB ends it too: the rest of it would be read as the next list. paddock
		// sends none that long.
		line, err := lines.ReadSlice('\n')
		if err != nil {
			return
		}
		if _, err := conn.Write(append(takeList(line, current, logf), '\n')); err != nil {
			return
		}
	}
}

// takeList puts the list in line in force and answers {}, or keeps the old one and answers
// {"error":"..."}.
func takeList(line []byte, current *atomic.Pointer[policy], logf func(string, ...any)) []byte {
	var answer struct {
		Error string `json:"error,omitempty"`
	}
	var request struct {
		Allow []string `json:"allow"`
	}
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
	return reply
}
