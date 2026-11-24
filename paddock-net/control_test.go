package main

import (
	"bufio"
	"net"
	"testing"
)

func TestControlReplacesTheListOrKeepsItOnABadOne(t *testing.T) {
	paddock, paddockNet := net.Pipe()
	t.Cleanup(func() { paddock.Close() })
	current := holding(&policy{})
	go serveControl(paddockNet, current, t.Logf)
	answers := bufio.NewReader(paddock)
	ask := func(line string) string {
		t.Helper()
		if _, err := paddock.Write([]byte(line + "\n")); err != nil {
			t.Fatal(err)
		}
		answer, err := answers.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		return answer
	}

	if answer := ask(`{"allow":["github.com","*.example.org"]}`); answer != "{}\n" {
		t.Fatalf("answer %q, want {}", answer)
	}
	if !current.Load().allows("github.com") || !current.Load().allows("a.example.org") {
		t.Error("the new list isn't in force")
	}

	if answer := ask(`{"allow":["*"]}`); answer == "{}\n" {
		t.Error("took * as a list")
	}
	if answer := ask(`not json`); answer == "{}\n" {
		t.Error("took a line that isn't JSON")
	}
	if !current.Load().allows("github.com") {
		t.Error("a refused list replaced the one in force")
	}

	if answer := ask(`{"allow":[]}`); answer != "{}\n" || current.Load().allows("github.com") {
		t.Errorf("an empty list: answer %q, and github.com still allowed: %v", answer, current.Load().allows("github.com"))
	}
}
