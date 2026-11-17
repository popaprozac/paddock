package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func askControl(t *testing.T, path, line string) string {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(line + "\n")); err != nil {
		t.Fatal(err)
	}
	answer, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	return answer
}

func TestControlReplacesTheListOrKeepsItOnABadOne(t *testing.T) {
	// Unix socket paths are limited to 104 bytes, and t.TempDir() can be longer.
	dir, err := os.MkdirTemp("/tmp", "paddock-net-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "net.sock")
	p, _ := parsePolicy("")
	current := holding(p)
	if err := serveControl(path, current, t.Logf); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v, %v; want 0600", info.Mode().Perm(), err)
	}

	if answer := askControl(t, path, `{"allow":["github.com","*.example.org"]}`); answer != "{}\n" {
		t.Fatalf("answer %q, want {}", answer)
	}
	if !current.Load().allows("github.com") || !current.Load().allows("a.example.org") {
		t.Error("the new list isn't in force")
	}

	if answer := askControl(t, path, `{"allow":["*"]}`); answer == "{}\n" {
		t.Error("took * as a list")
	}
	if answer := askControl(t, path, `not json`); answer == "{}\n" {
		t.Error("took a line that isn't JSON")
	}
	if !current.Load().allows("github.com") {
		t.Error("a refused list replaced the one in force")
	}

	if answer := askControl(t, path, `{"allow":[]}`); answer != "{}\n" || current.Load().allows("github.com") {
		t.Errorf("an empty list: answer %q, and github.com still allowed: %v", answer, current.Load().allows("github.com"))
	}
}
