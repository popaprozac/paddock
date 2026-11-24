// paddock-guestd for Linux is the agent inside each Linux guest. It speaks the protocol in
// docs/guest-agent.md, as the macOS agent (Sources/PaddockCore/GuestAgent.swift) does, on vsock
// port 52525, and answers only the host. systemd runs it as root and starts it again if it
// exits. Commands, put and get run as the workload account, the one with uid 1000.
package main

import (
	"log"
	"os"
	"time"
)

// The host's vsock address. A process in the guest can reach the guest's own vsock listeners
// through vsock loopback; the guest's kernel sets the peer's CID, so only the host's connections
// come from this one.
const hostCID = 2

func fromHost(cid uint32) bool { return cid == hostCID }

func main() {
	log.SetFlags(0)
	// How the axtree request reads the desktop: this binary again, as the workload account.
	if len(os.Args) == 2 && os.Args[1] == "axtree" {
		os.Exit(printFocusedTree(os.Stdout, os.Stderr))
	}
	user, err := lookupAccount("1000")
	if err != nil {
		log.Fatalf("paddock-guestd: no account with uid 1000 to run commands as: %v", err)
	}
	root, err := lookupAccount("0")
	if err != nil {
		log.Fatalf("paddock-guestd: no root account: %v", err)
	}
	fd, err := listen(port)
	if err != nil {
		log.Fatalf("paddock-guestd: can't listen on vsock port %d: %v", port, err)
	}
	a := &agent{user: user, root: root, files: user.home + "/paddock", shell: []string{"/bin/bash", "-lc"},
		setClock: setSystemClock}
	log.Printf("paddock-guestd %s listening on vsock port %d, running commands as '%s'", version, port, user.name)
	for {
		c, cid, err := accept(fd)
		if err != nil {
			log.Printf("paddock-guestd: accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		if !fromHost(cid) {
			log.Printf("paddock-guestd: refused a connection from vsock CID %d", cid)
			c.Close()
			continue
		}
		go a.serve(c)
	}
}

var _ conn = (*os.File)(nil)
