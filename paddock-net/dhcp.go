package main

import (
	"bytes"
	"errors"
	"net"
	"time"

	"github.com/insomniacslk/dhcp/dhcpv4"
	"github.com/insomniacslk/dhcp/dhcpv4/server4"
	log "github.com/sirupsen/logrus"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// infiniteLease is DHCP's lease time for one that never expires (RFC 2131).
const infiniteLease = 0xffffffff * time.Second

// serveDHCP gives the guest with mac the address guestIP, with the gateway as its router and DNS
// server, on a lease that never expires. The guest is alone on its network and its address never
// changes. A lease that expires would break restores: the slot's guest leases its address while
// its clock is still where golden's last shutdown left it, NTP then moves the clock forward,
// often by hours, and every restore of the saved state finds the lease expired and goes through
// DHCP from the start, which takes macOS 1.6 s longer than reusing it. Follows gvisor-tap-vsock's
// dhcp package (Apache 2.0), which leases for an hour.
func serveDHCP(s *stack.Stack, mac string) error {
	guestMAC, err := net.ParseMAC(mac)
	if err != nil {
		return err
	}
	var wq waiter.Queue
	ep, tcpErr := s.NewEndpoint(udp.ProtocolNumber, ipv4.ProtocolNumber, &wq)
	if tcpErr != nil {
		return errors.New(tcpErr.String())
	}
	ep.SocketOptions().SetBroadcast(true)
	if tcpErr := ep.Bind(tcpip.FullAddress{NIC: nic, Port: 67}); tcpErr != nil {
		ep.Close()
		return errors.New(tcpErr.String())
	}
	handler := func(conn net.PacketConn, peer net.Addr, m *dhcpv4.DHCPv4) {
		if reply := dhcpReply(m, guestMAC); reply != nil {
			_, _ = conn.WriteTo(reply.ToBytes(), peer)
		}
	}
	server, err := server4.NewServer("", nil, handler, server4.WithConn(gonet.NewUDPConn(&wq, ep)))
	if err != nil {
		return err
	}
	go func() { log.Error(server.Serve()) }()
	return nil
}

// dhcpReply answers the guest's discover with an offer and its request with an ack, or returns
// nil for anything else, or anyone else.
func dhcpReply(m *dhcpv4.DHCPv4, guestMAC net.HardwareAddr) *dhcpv4.DHCPv4 {
	if !bytes.Equal(m.ClientHWAddr, guestMAC) {
		return nil
	}
	var kind dhcpv4.MessageType
	switch m.MessageType() {
	case dhcpv4.MessageTypeDiscover:
		kind = dhcpv4.MessageTypeOffer
	case dhcpv4.MessageTypeRequest:
		kind = dhcpv4.MessageTypeAck
	default:
		return nil
	}
	gateway := net.ParseIP(gatewayIP).To4()
	_, network, err := net.ParseCIDR(subnet)
	if err != nil {
		return nil
	}
	reply, err := dhcpv4.NewReplyFromRequest(m,
		dhcpv4.WithMessageType(kind),
		dhcpv4.WithYourIP(net.ParseIP(guestIP).To4()),
		dhcpv4.WithServerIP(gateway),
		dhcpv4.WithOption(dhcpv4.OptServerIdentifier(gateway)),
		dhcpv4.WithOption(dhcpv4.OptIPAddressLeaseTime(infiniteLease)),
		dhcpv4.WithNetmask(network.Mask),
		dhcpv4.WithRouter(gateway),
		dhcpv4.WithDNS(gateway),
		dhcpv4.WithOption(dhcpv4.Option{Code: dhcpv4.OptionInterfaceMTU, Value: dhcpv4.Uint16(mtu)}),
	)
	if err != nil {
		return nil
	}
	return reply
}
