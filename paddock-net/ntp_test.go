package main

import (
	"bytes"
	"encoding/binary"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func ntpSeconds(b []byte) int64 {
	return int64(binary.BigEndian.Uint32(b)) - ntpEpochOffset
}

func TestNTPAnswersAClientWithTheHostsTime(t *testing.T) {
	request := make([]byte, 48)
	request[0] = 4<<3 | 3 // version 4, client
	request[2] = 6
	copy(request[40:], []byte{1, 2, 3, 4, 5, 6, 7, 8})
	received := time.Unix(1_800_000_000, 0)
	sent := received.Add(time.Millisecond)

	reply := ntpReply(request, received, func() time.Time { return sent })
	if len(reply) != 48 || reply[0] != 4<<3|4 || reply[1] != 2 || reply[2] != 6 {
		t.Fatalf("header %v, want version 4, server, stratum 2, poll 6", reply[:4])
	}
	if !bytes.Equal(reply[24:32], request[40:48]) {
		t.Errorf("origin %v, want the client's transmit time", reply[24:32])
	}
	if ntpSeconds(reply[32:]) != received.Unix() || ntpSeconds(reply[40:]) != sent.Unix() {
		t.Errorf("receive %d and transmit %d, want %d and %d",
			ntpSeconds(reply[32:]), ntpSeconds(reply[40:]), received.Unix(), sent.Unix())
	}
}

func TestNTPIgnoresWhatIsNotAClientRequest(t *testing.T) {
	server := make([]byte, 48)
	server[0] = 4<<3 | 4
	for _, request := range [][]byte{server, make([]byte, 47), nil} {
		if reply := ntpReply(request, time.Now(), time.Now); reply != nil {
			t.Errorf("answered %v", request)
		}
	}
}

func TestDNSPointsTheTimeServerAtTheGatewayWhateverTheList(t *testing.T) {
	h, looked := testDNS(t)
	m := h.answer(query("Time.Apple.com", dns.TypeA))
	if m.Rcode != dns.RcodeSuccess || len(m.Answer) != 1 || m.Answer[0].(*dns.A).A.String() != gatewayIP {
		t.Fatalf("got rcode %d, answers %v; want %s", m.Rcode, m.Answer, gatewayIP)
	}
	if m := h.answer(query("time.apple.com", dns.TypeAAAA)); m.Rcode != dns.RcodeSuccess || len(m.Answer) != 0 {
		t.Errorf("AAAA: rcode %d, answers %v; want an empty answer", m.Rcode, m.Answer)
	}
	if len(*looked) != 0 {
		t.Errorf("asked the host about %v", *looked)
	}
}
