// paddock-guestd for Windows is the agent inside each Windows guest (spike). It speaks the
// protocol in docs/guest-agent.md, as the macOS and Linux agents do, on vsock port 52525, and
// answers only the host. For now it answers health and state; run, put, get and axtree are still
// to come. It runs as SYSTEM, started at boot by a scheduled task.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"log"
	"time"
)

const (
	version    = "0.1.0"
	port       = 52525
	maxRequest = 64 * 1024
	// The host's vsock address. viosock sets the peer's CID, so only the host's connections come
	// from this one.
	hostCID = 2
)

// idle is how long a client may send nothing before the agent gives up on it, as the other agents do.
var idle = 5 * time.Second

type request struct {
	Op string `json:"op"`
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
func output(line string) response    { return response{Output: &line} }

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

// serve answers one connection: one request line, then one or more answer lines, sent in one write.
func serve(c *vsockConn) {
	defer c.Close()
	c.setReadTimeout(idle)
	line, err := bufio.NewReaderSize(c, maxRequest).ReadSlice('\n')
	if err != nil {
		return
	}
	var out bytes.Buffer
	for _, r := range handle(bytes.TrimRight(line, "\r\n")) {
		b, _ := json.Marshal(r)
		out.Write(append(b, '\n'))
	}
	io.Copy(c, &out)
}

func handle(line []byte) []response {
	var r request
	if json.Unmarshal(line, &r) != nil || r.Op == "" {
		return []response{failed("unreadable request")}
	}
	switch r.Op {
	case "health":
		v := version
		return []response{{Version: &v}}
	case "state":
		var answers []response
		for _, s := range state() {
			answers = append(answers, output(s))
		}
		return append(answers, exited(0))
	}
	// The host reads "unknown request" as an agent that predates the request.
	return []response{failed("unknown request '" + r.Op + "'")}
}
