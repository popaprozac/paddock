package main

import (
	"net"
	"testing"

	"github.com/insomniacslk/dhcp/dhcpv4"
)

func dhcpMessage(t *testing.T, mac string, kind dhcpv4.MessageType) *dhcpv4.DHCPv4 {
	t.Helper()
	hw, _ := net.ParseMAC(mac)
	m, err := dhcpv4.New(dhcpv4.WithHwAddr(hw), dhcpv4.WithMessageType(kind))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestDHCPLeasesTheGuestItsAddressForever(t *testing.T) {
	guest, _ := net.ParseMAC("a6:7b:b2:fe:9d:77")
	for request, want := range map[dhcpv4.MessageType]dhcpv4.MessageType{
		dhcpv4.MessageTypeDiscover: dhcpv4.MessageTypeOffer,
		dhcpv4.MessageTypeRequest:  dhcpv4.MessageTypeAck,
	} {
		reply := dhcpReply(dhcpMessage(t, guest.String(), request), guest)
		if reply == nil {
			t.Fatalf("no reply to %v", request)
		}
		if reply.MessageType() != want || reply.YourIPAddr.String() != guestIP {
			t.Errorf("%v: got %v for %v, want %v for %s", request, reply.MessageType(), reply.YourIPAddr, want, guestIP)
		}
		if lease := reply.IPAddressLeaseTime(0); lease != infiniteLease {
			t.Errorf("%v: lease %v, want infinite", request, lease)
		}
		if router := reply.Router(); len(router) != 1 || router[0].String() != gatewayIP {
			t.Errorf("%v: router %v, want %s", request, router, gatewayIP)
		}
		if dns := reply.DNS(); len(dns) != 1 || dns[0].String() != gatewayIP {
			t.Errorf("%v: DNS %v, want %s", request, dns, gatewayIP)
		}
	}
}

func TestDHCPAnswersOnlyTheGuestsDiscoverAndRequest(t *testing.T) {
	guest, _ := net.ParseMAC("a6:7b:b2:fe:9d:77")
	if dhcpReply(dhcpMessage(t, "02:00:00:00:00:01", dhcpv4.MessageTypeDiscover), guest) != nil {
		t.Error("answered another MAC address")
	}
	if dhcpReply(dhcpMessage(t, guest.String(), dhcpv4.MessageTypeRelease), guest) != nil {
		t.Error("answered a release")
	}
}
