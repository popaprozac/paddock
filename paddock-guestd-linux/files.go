package main

import (
	"fmt"
	"io"
)

// put and get move files between the host and the workload account's ~/paddock folder. The
// account itself reads and writes them, never the root agent, so a symlink planted in the folder
// reaches only what that account could anyway.

// put stores the `size` bytes that follow the request as `name`, readable only by the account.
func (a *agent) put(name string, size int64, in io.Reader) response {
	cmd := a.command([]string{"/bin/sh", "-c", `umask 077 && mkdir -p "$1" && cat > "$1/$2"`, "sh", a.files, name}, a.user)
	stdin, err := cmd.StdinPipe()
	if err == nil {
		err = cmd.Start()
	}
	if err != nil {
		return failed(fmt.Sprintf("can't store '%s': %v", name, err))
	}
	copied, _ := io.CopyN(stdin, in, size)
	stdin.Close()
	err = cmd.Wait()
	if copied < size {
		return failed(fmt.Sprintf("'%s' stopped after %d of %d bytes", name, copied, size))
	}
	if err != nil {
		return failed(fmt.Sprintf("can't store '%s' in the guest", name))
	}
	return exited(0)
}

// get sends `name` as chunks: a {"chunk":n} line and n bytes each.
func (a *agent) get(name string, out *answerer) response {
	cmd := a.command([]string{"/bin/cat", a.files + "/" + name}, a.user)
	stdout, err := cmd.StdoutPipe()
	if err == nil {
		err = cmd.Start()
	}
	if err != nil {
		return failed(fmt.Sprintf("can't read '%s': %v", name, err))
	}
	buf := make([]byte, fileChunk)
	for !out.gone {
		n, err := stdout.Read(buf)
		if n > 0 {
			out.sendChunk(buf[:n])
		}
		if err != nil {
			break
		}
	}
	if out.gone {
		cmd.Process.Kill() // nobody reads the rest; cat would block on a full pipe
	}
	if cmd.Wait() != nil {
		return failed(fmt.Sprintf("can't read '%s' in the guest", name))
	}
	return exited(0)
}
