// paddock-guestd for Windows is the agent inside each Windows guest (spike). It speaks the
// protocol in docs/guest-agent.md, as the macOS and Linux agents do, on vsock port 52525, and
// answers only the host. It answers health, state, run and clock; put, get and axtree are still to
// come. It runs as SYSTEM, started at boot by a scheduled task. Commands run as the account signed
// in at the console, or as SYSTEM when the host asks for root.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"time"
)

const (
	version    = "0.2.0"
	port       = 52525
	maxRequest = 64 * 1024
	// The host's vsock address. viosock sets the peer's CID, so only the host's connections come
	// from this one.
	hostCID = 2
)

// idle is how long a client may send nothing before the agent gives up on it, as the other agents do.
var idle = 5 * time.Second

type request struct {
	Op      string  `json:"op"`
	Command *string `json:"command"`
	User    *string `json:"as"`   // for run: "root", or nil for the workload account
	Time    *int64  `json:"time"` // for clock: the host's time, in nanoseconds since 1970
}

// response is one answer line; exactly the fields that are set go out.
type response struct {
	Version *string `json:"version,omitempty"`
	Output  *string `json:"output,omitempty"`
	Exit    *int    `json:"exit,omitempty"`
	Error   *string `json:"error,omitempty"`
}

func exited(status int) response     { return response{Exit: &status} }
func failed(message string) response { return response{Error: &message} }
func output(line []byte) response {
	text := string(line)
	return response{Output: &text}
}

func main() {
	log.SetFlags(0)
	listener, err := listen(port)
	if err != nil {
		log.Fatalf("paddock-guestd: can't listen on vsock port %d: %v", port, err)
	}
	log.Printf("paddock-guestd %s (Windows) listening on vsock port %d", version, port)
	for {
		c, cid, err := listener.accept()
		if err != nil {
			log.Printf("paddock-guestd: accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		if cid != hostCID {
			log.Printf("paddock-guestd: refused a connection from vsock CID %d", cid)
			c.Close()
			continue
		}
		go serve(c)
	}
}

// serve answers one connection: one request line, then one or more answer lines.
func serve(c *vsockConn) {
	defer c.Close()
	c.setReadTimeout(idle)
	line, err := bufio.NewReaderSize(c, maxRequest).ReadSlice('\n')
	if err != nil {
		return
	}
	out := &answerer{w: c}
	out.send(handle(bytes.TrimRight(line, "\r\n"), out))
}

func handle(line []byte, out *answerer) response {
	var r request
	if json.Unmarshal(line, &r) != nil || r.Op == "" {
		return failed("unreadable request")
	}
	switch r.Op {
	case "health":
		v := version
		return response{Version: &v}
	case "state":
		for _, s := range state() {
			out.send(output([]byte(s)))
		}
		return exited(0)
	case "run":
		if r.Command == nil {
			return failed("run needs a command")
		}
		switch {
		case r.User == nil:
			return run(*r.Command, false, out)
		case *r.User == "root":
			return run(*r.Command, true, out)
		default:
			return failed(fmt.Sprintf("run as 'root' or as the workload account, not '%.64s'", *r.User))
		}
	case "clock":
		if r.Time == nil {
			return failed("clock needs a time")
		}
		if err := setClock(time.Unix(0, *r.Time)); err != nil {
			return failed("can't set the clock: " + err.Error())
		}
		return exited(0)
	}
	// The host reads "unknown request" as an agent that predates the request.
	return failed("unknown request '" + r.Op + "'")
}

// answerer writes one connection's answer lines. Lines that arrive together go out in one
// write, as the Linux agent's do: many small vsock packets stall Virtualization.framework's
// vsock. Once a write fails, the client is gone, and the rest is dropped.
type answerer struct {
	w    io.Writer
	gone bool
}

func (o *answerer) send(rs ...response) {
	var b bytes.Buffer
	for _, r := range rs {
		line, _ := json.Marshal(r)
		b.Write(line)
		b.WriteByte('\n')
	}
	if b.Len() == 0 || o.gone {
		return
	}
	if _, err := o.w.Write(b.Bytes()); err != nil {
		o.gone = true
	}
}
