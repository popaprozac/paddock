// paddock-guestd for Windows is the agent inside each Windows guest (spike). It speaks the
// protocol in docs/guest-agent.md, as the macOS and Linux agents do, on vsock port 52525, and
// answers only the host. It answers health, state, run, put, get, clock and axtree. It runs as
// SYSTEM, started at boot by a scheduled task. Commands, file transfers and the reading of the
// accessibility tree run as the account signed in at the console; commands run as SYSTEM when the
// host asks for root.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"time"
)

const (
	version    = "0.4.0"
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
	Name    *string `json:"name"` // for put and get: a file in the account's paddock folder
	Size    *int64  `json:"size"` // for put: how many bytes follow the request line
	Time    *int64  `json:"time"` // for clock: the host's time, in nanoseconds since 1970
}

// response is one answer line; exactly the fields that are set go out.
type response struct {
	Version *string `json:"version,omitempty"`
	Output  *string `json:"output,omitempty"`
	Chunk   *int    `json:"chunk,omitempty"`
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
	// How the axtree request reads the desktop: this binary again, as the account signed in.
	if len(os.Args) == 2 && os.Args[1] == "axtree" {
		os.Exit(printFocusedTree(os.Stdout, os.Stderr))
	}
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
	in := bufio.NewReaderSize(c, maxRequest)
	line, err := in.ReadSlice('\n')
	if err != nil {
		return
	}
	out := &answerer{w: c}
	out.send(handle(bytes.TrimRight(line, "\r\n"), in, out))
}

// handle answers one request; `in` reads what follows its line, such as a put's bytes.
func handle(line []byte, in io.Reader, out *answerer) response {
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
	case "put":
		if r.Name == nil || !isFileName(*r.Name) || r.Size == nil || *r.Size < 0 || *r.Size > maxFileSize {
			return failed(fmt.Sprintf("put needs a plain file name and a size up to %d bytes", maxFileSize))
		}
		return put(*r.Name, *r.Size, in)
	case "get":
		if r.Name == nil || !isFileName(*r.Name) {
			return failed("get needs a plain file name")
		}
		return get(*r.Name, out)
	case "clock":
		if r.Time == nil {
			return failed("clock needs a time")
		}
		if err := setClock(time.Unix(0, *r.Time)); err != nil {
			return failed("can't set the clock: " + err.Error())
		}
		return exited(0)
	case "axtree":
		return axtree(out)
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

// sendChunk sends a chunk line and its bytes in one write.
func (o *answerer) sendChunk(data []byte) {
	n := len(data)
	line, _ := json.Marshal(response{Chunk: &n})
	o.write(append(append(line, '\n'), data...))
}

func (o *answerer) send(rs ...response) {
	var b bytes.Buffer
	for _, r := range rs {
		line, _ := json.Marshal(r)
		b.Write(line)
		b.WriteByte('\n')
	}
	o.write(b.Bytes())
}

func (o *answerer) write(b []byte) {
	if len(b) == 0 || o.gone {
		return
	}
	if _, err := o.w.Write(b); err != nil {
		o.gone = true
	}
}
