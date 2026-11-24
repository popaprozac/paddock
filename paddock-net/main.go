// paddock-net is the userspace network stack for one paddock VM.
//
// Its stdin is a datagram socket carrying the VM's Ethernet frames, one per datagram, the way
// Virtualization.framework's file-handle network attachment sends them. It answers DHCP with a
// fixed address and lets the guest reach only the names on its list: DNS answers those names and
// refuses the rest, and TCP to ports 80 and 443 is carried out through the host's own sockets to
// the name the guest asks for, if it is on the list. Everything else the guest sends goes
// nowhere. Nothing on the host's networks can open a connection to the guest. The list starts
// empty, and paddock replaces it while the VM runs over stdout, a stream socket whose other end
// only paddock holds. It logs each decision to stderr and exits when the paddock process that
// started it does.
package main

import (
	"context"
	"flag"
	stdlog "log"
	"net"
	"os"
	"sync/atomic"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	log "github.com/sirupsen/logrus"
	"golang.org/x/time/rate"
)

func main() {
	mac := flag.String("mac", "", "the guest's MAC address, which DHCP gives "+guestIP)
	flag.Parse()
	if _, err := net.ParseMAC(*mac); err != nil {
		stdlog.Fatalf("paddock-net: -mac: %v", err)
	}
	log.SetLevel(log.WarnLevel) // gvisor-tap-vsock's own logging

	logf := limitedLog(stdlog.New(os.Stderr, "paddock-net: ", stdlog.LstdFlags), rate.NewLimiter(50, 200))
	current := holding(&policy{})
	networkSwitch, err := newNetwork(*mac, current, logf)
	if err != nil {
		stdlog.Fatalf("paddock-net: %v", err)
	}
	control, err := net.FileConn(os.Stdout)
	if err != nil {
		stdlog.Fatalf("paddock-net: stdout must be paddock's control socket: %v", err)
	}
	os.Stdout = os.Stderr // nothing else may write into the control socket
	go serveControl(control, current, logf)
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

// limitedLog logs as often as limit allows, so a guest that loops on refused names can't fill the
// disk through serve's log. It counts the lines over the limit, and the next line out says how
// many there were.
func limitedLog(logger *stdlog.Logger, limit *rate.Limiter) func(string, ...any) {
	var dropped atomic.Int64
	return func(format string, args ...any) {
		if !limit.Allow() {
			dropped.Add(1)
			return
		}
		if n := dropped.Swap(0); n > 0 {
			logger.Printf("dropped %d lines, over %g a second", n, float64(limit.Limit()))
		}
		logger.Printf(format, args...)
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
