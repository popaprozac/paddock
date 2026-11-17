package main

import (
	"errors"
	"fmt"
	"net"
	"sync/atomic"

	"github.com/containers/gvisor-tap-vsock/pkg/tap"
	"github.com/miekg/dns"
	log "github.com/sirupsen/logrus"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/arp"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// The guest's address; paddock's UserspaceNetwork.guestIP must match.
const (
	subnet     = "192.168.127.0/24"
	gatewayIP  = "192.168.127.1"
	gatewayMAC = "5a:94:ef:e4:0c:dd"
	guestIP    = "192.168.127.2"
	mtu        = 1500
	nic        = 1
)

// newNetwork builds the guest's network on gvisor-tap-vsock's switch, with paddock-net's own
// DHCP, DNS and TCP handling in place of its services and forwarders, which would carry anything
// anywhere. It follows gvisor-tap-vsock's virtualnetwork.New (Apache 2.0). The returned switch
// accepts the VM's frames; p holds the policy in force.
func newNetwork(mac string, p *atomic.Pointer[policy], logf func(string, ...any)) (*tap.Switch, error) {
	endpoint, err := tap.NewLinkEndpoint(false, mtu, gatewayMAC, gatewayIP, nil)
	if err != nil {
		return nil, err
	}
	networkSwitch := tap.NewSwitch(false)
	endpoint.Connect(networkSwitch)
	networkSwitch.Connect(endpoint)

	s, err := newStack(endpoint)
	if err != nil {
		return nil, err
	}
	// The only transport handler is TCP's: datagrams to anything but the gateway's DNS, NTP and
	// DHCP find no endpoint and are dropped, and pings never leave the host.
	f := &forwarder{policy: p, dial: hostDialer.DialContext, logf: logf}
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcp.NewForwarder(s, 0, 128, f.handle).HandlePacket)

	if err := serveDNS(s, &dnsHandler{policy: p, lookup: lookupIPv4, logf: logf}); err != nil {
		return nil, fmt.Errorf("DNS: %w", err)
	}
	ntpConn, err := gonet.DialUDP(s, &tcpip.FullAddress{NIC: nic, Addr: gateway(), Port: 123}, nil, ipv4.ProtocolNumber)
	if err != nil {
		return nil, fmt.Errorf("NTP: %w", err)
	}
	go serveNTP(ntpConn)
	if err := serveDHCP(s, mac); err != nil {
		return nil, fmt.Errorf("DHCP: %w", err)
	}
	return networkSwitch, nil
}

// newStack makes the gateway: an IPv4 stack that takes packets for any address, so the TCP
// forwarder sees every connection whatever address the guest picked.
func newStack(endpoint stack.LinkEndpoint) (*stack.Stack, error) {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, arp.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol, icmp.NewProtocol4},
	})
	if err := s.CreateNIC(nic, endpoint); err != nil {
		return nil, errors.New(err.String())
	}
	if err := s.AddProtocolAddress(nic, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: gateway().WithPrefix(),
	}, stack.AddressProperties{}); err != nil {
		return nil, errors.New(err.String())
	}
	s.SetSpoofing(nic, true)
	s.SetPromiscuousMode(nic, true)

	_, parsed, err := net.ParseCIDR(subnet)
	if err != nil {
		return nil, err
	}
	route, err := tcpip.NewSubnet(tcpip.AddrFromSlice(parsed.IP.To4()), tcpip.MaskFromBytes(parsed.Mask))
	if err != nil {
		return nil, err
	}
	s.SetRouteTable([]tcpip.Route{{Destination: route, NIC: nic}})
	return s, nil
}

// serveDNS answers DNS on the gateway's port 53, over UDP and TCP.
func serveDNS(s *stack.Stack, handler dns.Handler) error {
	address := tcpip.FullAddress{NIC: nic, Addr: gateway(), Port: 53}
	udpConn, err := gonet.DialUDP(s, &address, nil, ipv4.ProtocolNumber)
	if err != nil {
		return err
	}
	tcpListener, err := gonet.ListenTCP(s, address, ipv4.ProtocolNumber)
	if err != nil {
		return err
	}
	go func() { log.Error((&dns.Server{PacketConn: udpConn, Handler: handler}).ActivateAndServe()) }()
	go func() { log.Error((&dns.Server{Listener: tcpListener, Handler: handler}).ActivateAndServe()) }()
	return nil
}

func gateway() tcpip.Address {
	return tcpip.AddrFrom4Slice(net.ParseIP(gatewayIP).To4())
}
