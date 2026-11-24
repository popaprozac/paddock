package main

import (
	"context"
	"net"
	"os"
	"syscall"
	"testing"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// datagramPair is a connected pair of datagram sockets, as the VM's network attachment is.
func datagramPair(t *testing.T) (vm, ours net.Conn) {
	t.Helper()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	wrap := func(fd int) net.Conn {
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 1<<20)
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 1<<20)
		f := os.NewFile(uintptr(fd), "pair")
		defer f.Close()
		c, err := net.FileConn(f)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return c
	}
	return wrap(fds[0]), wrap(fds[1])
}

// arpRequest is a frame from `from` asking who has the gateway's address.
func arpRequest(from net.HardwareAddr) []byte {
	frame := make([]byte, header.EthernetMinimumSize+header.ARPSize)
	header.Ethernet(frame).Encode(&header.EthernetFields{
		SrcAddr: tcpip.LinkAddress(from), DstAddr: header.EthernetBroadcastAddress, Type: header.ARPProtocolNumber,
	})
	arp := header.ARP(frame[header.EthernetMinimumSize:])
	arp.SetIPv4OverEthernet()
	arp.SetOp(header.ARPRequest)
	copy(arp.HardwareAddressSender(), from)
	copy(arp.ProtocolAddressSender(), net.ParseIP(guestIP).To4())
	copy(arp.ProtocolAddressTarget(), net.ParseIP(gatewayIP).To4())
	return frame
}

// A guest can't stop the switch with frames too short for an Ethernet header, or grow it by
// sending from made-up MAC addresses, and the frames it sends from its own still get answers.
func TestTheSwitchTakesOnlyWholeFramesFromTheGuestsAddress(t *testing.T) {
	const guest = "a6:7b:b2:fe:9d:77"
	mac, _ := net.ParseMAC(guest)
	networkSwitch, err := newNetwork(guest, holding(&policy{}), t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	vm, ours := datagramPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = networkSwitch.Accept(ctx, guestFrames{ours, mac}, types.VfkitProtocol) }()

	broadcast := []byte(header.EthernetBroadcastAddress)
	frames := [][]byte{{1, 2, 3}, append(broadcast, 2, 0, 0, 0)}
	for i := range 100 {
		frames = append(frames, arpRequest(net.HardwareAddr{2, 0, 0, 0, 0, byte(i)}))
	}
	frames = append(frames, arpRequest(mac))
	for _, frame := range frames {
		if _, err := vm.Write(frame); err != nil {
			t.Fatal(err)
		}
	}

	_ = vm.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 2048)
	for {
		n, err := vm.Read(buf)
		if err != nil {
			t.Fatalf("no ARP answer to the guest: %v", err)
		}
		if eth := header.Ethernet(buf[:n]); eth.Type() == header.ARPProtocolNumber && eth.DestinationAddress() == tcpip.LinkAddress(mac) {
			break
		}
	}
	if learned := networkSwitch.CAM(); len(learned) != 1 {
		t.Errorf("the switch learned %d addresses, want only %s's", len(learned), guest)
	}
}
