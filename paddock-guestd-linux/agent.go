package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"
	"time"
)

const (
	version = "0.1.0"
	port    = 52525
	// Output lines longer than this are split, so every answer line stays well under the 64 KB
	// the host's reader accepts even after JSON escaping.
	outputChunk = 8 * 1024
	fileChunk   = 1 << 20
	maxFileSize = int64(4) << 30
	maxRequest  = 64 * 1024
)

// idle is how long a client may send nothing before the agent gives up on it, as the macOS
// agent's socket timeout.
var idle = 5 * time.Second

type request struct {
	Op      string  `json:"op"`
	Command *string `json:"command"`
	Name    *string `json:"name"`
	Size    *int64  `json:"size"`
	User    *string `json:"as"`   // for run: "root", or nil for the workload account
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

// account is who a command runs as.
type account struct {
	name   string
	home   string
	uid    uint32
	gid    uint32
	groups []uint32
}

func lookupAccount(uid string) (*account, error) {
	u, err := user.LookupId(uid)
	if err != nil {
		return nil, err
	}
	a := &account{name: u.Username, home: u.HomeDir}
	ids, err := u.GroupIds()
	if err != nil {
		return nil, err
	}
	for _, id := range append([]string{u.Uid, u.Gid}, ids...) {
		n, err := strconv.ParseUint(id, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("unreadable id %q for %s", id, u.Username)
		}
		a.groups = append(a.groups, uint32(n))
	}
	a.uid, a.gid, a.groups = a.groups[0], a.groups[1], a.groups[2:]
	return a, nil
}

// agent answers the host's requests. A nil account runs commands as the agent's own user, as
// the tests do.
type agent struct {
	user     *account // the workload account
	root     *account // for "as":"root"
	files    string   // the folder put and get use: the workload account's ~/paddock
	shell    []string // what runs a command: a login bash in the guest
	setClock func(time.Time) error
}

// conn is one client's connection: a vsock socket in the guest, a socket pair in the tests.
type conn interface {
	io.ReadWriteCloser
	SetReadDeadline(time.Time) error
}

// timed reads from a connection, giving up once the client sends nothing for `idle`.
type timed struct{ c conn }

func (t timed) Read(p []byte) (int, error) {
	t.c.SetReadDeadline(time.Now().Add(idle))
	return t.c.Read(p)
}

// serve answers one connection: one request line, then one or more answer lines.
func (a *agent) serve(c conn) {
	defer c.Close()
	in := bufio.NewReaderSize(timed{c}, maxRequest)
	line, err := in.ReadSlice('\n')
	if err != nil {
		return
	}
	out := &answerer{w: c}
	out.send(a.handle(bytes.TrimRight(line, "\r\n"), in, out))
}

func (a *agent) handle(line []byte, in io.Reader, out *answerer) response {
	var r request
	if json.Unmarshal(line, &r) != nil || r.Op == "" {
		return failed("unreadable request")
	}
	switch r.Op {
	case "health":
		v := version
		return response{Version: &v}
	case "run":
		if r.Command == nil {
			return failed("run needs a command")
		}
		switch {
		case r.User == nil:
			return a.run(*r.Command, a.user, out)
		case *r.User == "root":
			return a.run(*r.Command, a.root, out)
		default:
			return failed(fmt.Sprintf("run as 'root' or as the workload account, not '%s'", prefix(*r.User)))
		}
	case "put":
		if r.Name == nil || !isFileName(*r.Name) || r.Size == nil || *r.Size < 0 || *r.Size > maxFileSize {
			return failed(fmt.Sprintf("put needs a plain file name and a size up to %d bytes", maxFileSize))
		}
		return a.put(*r.Name, *r.Size, in)
	case "get":
		if r.Name == nil || !isFileName(*r.Name) {
			return failed("get needs a plain file name")
		}
		return a.get(*r.Name, out)
	case "state":
		for _, line := range state() {
			out.send(output([]byte(line)))
		}
		return exited(0)
	case "clock":
		if r.Time == nil {
			return failed("clock needs a time")
		}
		if err := a.setClock(time.Unix(0, *r.Time)); err != nil {
			return failed("can't set the clock: " + err.Error())
		}
		return exited(0)
	default:
		return failed(fmt.Sprintf("unknown request '%s'", prefix(r.Op)))
	}
}

func prefix(s string) string {
	if len(s) > 64 {
		return s[:64]
	}
	return s
}

// One plain path component, so a request can't name anything outside the folder.
func isFileName(name string) bool {
	return name != "" && len(name) <= 255 && name[0] != '.' && !bytes.ContainsAny([]byte(name), "/\x00")
}

// answerer writes one connection's answer lines. Lines that arrive together go out in one
// write: a guest answering line by line sends a vsock packet per line, and tens of thousands of
// small packets stall Virtualization.framework's vsock for good. Once a write fails, the client
// is gone, and the rest is dropped.
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
	o.write(b.Bytes())
}

// sendChunk sends a chunk line and its bytes as one piece.
func (o *answerer) sendChunk(data []byte) {
	n := len(data)
	line, _ := json.Marshal(response{Chunk: &n})
	o.write(append(append(line, '\n'), data...))
}

func (o *answerer) write(b []byte) {
	if len(b) == 0 || o.gone {
		return
	}
	if _, err := o.w.Write(b); err != nil {
		o.gone = true
	}
}

// command starts `args` as `as`, in its home folder, with stdin closed.
func (a *agent) command(args []string, as *account) *exec.Cmd {
	cmd := exec.Command(args[0], args[1:]...)
	if as != nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: as.uid, Gid: as.gid, Groups: as.groups}}
		cmd.Dir = as.home
		path := "/usr/local/bin:/usr/bin:/bin"
		if as.uid == 0 {
			path = "/usr/local/sbin:/usr/sbin:/sbin:" + path
		}
		cmd.Env = []string{"HOME=" + as.home, "USER=" + as.name, "LOGNAME=" + as.name, "SHELL=/bin/bash",
			"PATH=" + path, "LANG=C.UTF-8"}
	}
	return cmd
}

// run runs `command` and streams its combined stdout and stderr as output lines, then its exit
// status. The command runs on after the client leaves, as on macOS.
func (a *agent) run(command string, as *account, out *answerer) response {
	cmd := a.command(append(append([]string{}, a.shell...), command), as)
	r, w, err := os.Pipe()
	if err != nil {
		return failed("can't start the command: " + err.Error())
	}
	cmd.Stdout, cmd.Stderr = w, w
	err = cmd.Start()
	w.Close()
	if err != nil {
		r.Close()
		return failed("can't start the command: " + err.Error())
	}
	streamLines(r, out)
	r.Close()
	return exited(exitStatus(cmd.Wait()))
}

// streamLines sends what `r` gives as lines, splitting any over outputChunk, and sends all the
// lines one read brings at once.
func streamLines(r io.Reader, out *answerer) {
	buf := make([]byte, 64*1024)
	var pending []byte
	for {
		n, err := r.Read(buf)
		pending = append(pending, buf[:n]...)
		var lines []response
		for {
			i := bytes.IndexByte(pending, '\n')
			if i >= 0 && i <= outputChunk {
				lines = append(lines, output(pending[:i]))
				pending = pending[i+1:]
			} else if len(pending) > outputChunk {
				lines = append(lines, output(pending[:outputChunk]))
				pending = pending[outputChunk:]
			} else {
				break
			}
		}
		out.send(lines...)
		if err != nil {
			if len(pending) > 0 {
				out.send(output(pending))
			}
			return
		}
	}
}

// exitStatus is the command's exit status, or 128 plus the signal that ended it, as a shell
// reports it.
func exitStatus(err error) int {
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		if err != nil {
			return -1
		}
		return 0
	}
	if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	return exit.ExitCode()
}

func setSystemClock(t time.Time) error {
	tv := syscall.NsecToTimeval(t.UnixNano())
	return syscall.Settimeofday(&tv)
}
