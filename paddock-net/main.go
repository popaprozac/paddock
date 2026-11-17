// paddock-net is the userspace network stack for one paddock VM.
//
// Its stdin is a datagram socket carrying the VM's Ethernet frames, one per datagram, the way
// Virtualization.framework's file-handle network attachment sends them. It answers DHCP with a
// fixed address, resolves DNS through the host and carries the guest's outbound TCP and UDP
// through the host's own sockets. It gives the guest no way to the host's own services, and
// nothing on the host's networks can open a connection to the guest. It exits when the paddock
// process that started it does.
package main

import (
	"context"
	"flag"
	"net"
	"os"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
	log "github.com/sirupsen/logrus"
)

// The guest's address; paddock's UserspaceNetwork.guestIP must match.
const (
	subnet     = "192.168.127.0/24"
	gatewayIP  = "192.168.127.1"
	gatewayMAC = "5a:94:ef:e4:0c:dd"
	guestIP    = "192.168.127.2"
)

func main() {
	mac := flag.String("mac", "", "the guest's MAC address, which DHCP gives "+guestIP)
	flag.Parse()
	if _, err := net.ParseMAC(*mac); err != nil {
		log.Fatalf("paddock-net: -mac: %v", err)
	}
	log.SetLevel(log.WarnLevel)

	network, err := virtualnetwork.New(&types.Configuration{
		MTU:               1500,
		Subnet:            subnet,
		GatewayIP:         gatewayIP,
		GatewayMacAddress: gatewayMAC,
		DHCPStaticLeases:  map[string]string{guestIP: *mac},
		Protocol:          types.VfkitProtocol,
	})
	if err != nil {
		log.Fatalf("paddock-net: %v", err)
	}
	conn, err := net.FileConn(os.NewFile(0, "vm"))
	if err != nil {
		log.Fatalf("paddock-net: stdin must be the VM's datagram socket: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	go exitWithParent(cancel)
	if err := network.AcceptVfkit(ctx, conn); err != nil && ctx.Err() == nil {
		log.Fatalf("paddock-net: %v", err)
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
