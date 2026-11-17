// paddock-net is the userspace network stack for one paddock VM.
//
// Its stdin is a datagram socket carrying the VM's Ethernet frames, one per datagram, the way
// Virtualization.framework's file-handle network attachment sends them. It answers DHCP with a
// fixed address and lets the guest reach only the names on its -allow list: DNS answers those
// names and refuses the rest, and TCP to ports 80 and 443 is carried out through the host's own
// sockets to the name the guest asks for, if it is on the list. Everything else the guest sends
// goes nowhere. Nothing on the host's networks can open a connection to the guest. With
// -control, paddock can replace the list while the VM runs. It logs each decision to stderr and
// exits when the paddock process that started it does.
package main

import (
	"context"
	"flag"
	stdlog "log"
	"net"
	"os"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	log "github.com/sirupsen/logrus"
)

func main() {
	mac := flag.String("mac", "", "the guest's MAC address, which DHCP gives "+guestIP)
	allow := flag.String("allow", "", "comma-separated names the guest may reach, as host.example or *.example; none without it")
	control := flag.String("control", "", "a Unix socket path to listen on for new lists from paddock")
	flag.Parse()
	if _, err := net.ParseMAC(*mac); err != nil {
		stdlog.Fatalf("paddock-net: -mac: %v", err)
	}
	p, err := parsePolicy(*allow)
	if err != nil {
		stdlog.Fatalf("paddock-net: -allow: %v", err)
	}
	log.SetLevel(log.WarnLevel) // gvisor-tap-vsock's own logging

	logf := stdlog.New(os.Stderr, "paddock-net: ", stdlog.LstdFlags).Printf
	current := holding(p)
	networkSwitch, err := newNetwork(*mac, current, logf)
	if err != nil {
		stdlog.Fatalf("paddock-net: %v", err)
	}
	if *control != "" {
		if err := serveControl(*control, current, logf); err != nil {
			stdlog.Fatalf("paddock-net: -control: %v", err)
		}
	}
	conn, err := net.FileConn(os.NewFile(0, "vm"))
	if err != nil {
		stdlog.Fatalf("paddock-net: stdin must be the VM's datagram socket: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	go exitWithParent(cancel)
	if err := networkSwitch.Accept(ctx, conn, types.VfkitProtocol); err != nil && ctx.Err() == nil {
		stdlog.Fatalf("paddock-net: %v", err)
	}
}

// exitWithParent stops once the paddock process that started this one is gone, so a paddock
// that was killed doesn't leave its network stacks running.
func exitWithParent(cancel context.CancelFunc) {
	parent := os.Getppid()
	for range time.Tick(time.Second) {
		if os.Getppid() != parent {
			cancel()
			os.Exit(0)
		}
	}
}
