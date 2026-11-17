package main

import (
	"encoding/binary"
	"net"
	"time"
)

// A macOS guest's clock starts where it was when its state was saved, or for a cold boot where
// golden's last shutdown left it, and macOS corrects it from time.apple.com, which the guest
// can't reach. So paddock-net answers that name with the gateway and answers NTP there with the
// host's own time. Nothing leaves the host.
const timeServer = "time.apple.com"

const ntpEpochOffset = 2208988800 // seconds from 1900, NTP's epoch, to 1970

// serveNTP answers NTP requests on conn until it closes.
func serveNTP(conn net.PacketConn) {
	buf := make([]byte, 512)
	for {
		n, peer, err := conn.ReadFrom(buf)
		if err != nil {
			return
		}
		if reply := ntpReply(buf[:n], time.Now(), time.Now); reply != nil {
			_, _ = conn.WriteTo(reply, peer)
		}
	}
}

// ntpReply answers a client's request (mode 3) as a server (mode 4), or returns nil for anything
// else. received is when the request arrived; now gives the time it is sent.
func ntpReply(request []byte, received time.Time, now func() time.Time) []byte {
	if len(request) < 48 || request[0]&0x7 != 3 {
		return nil
	}
	reply := make([]byte, 48)
	reply[0] = (request[0]>>3&0x7)<<3 | 4      // no leap second warning, the client's version, server
	reply[1] = 2                               // stratum: the host's clock, synchronized by macOS
	reply[2] = request[2]                      // poll interval, as the client asked
	reply[3] = 0xec                            // precision: 2^-20 s
	binary.BigEndian.PutUint32(reply[8:], 655) // root dispersion: 10 ms, in 16.16 seconds
	copy(reply[12:16], "HOST")
	putNTPTime(reply[16:], received)   // reference time
	copy(reply[24:32], request[40:48]) // origin: the client's transmit time, echoed
	putNTPTime(reply[32:], received)
	putNTPTime(reply[40:], now())
	return reply
}

// putNTPTime writes t as NTP's 32.32 seconds since 1900. The seconds wrap in 2036, as NTP's do.
func putNTPTime(b []byte, t time.Time) {
	binary.BigEndian.PutUint32(b, uint32(uint64(t.Unix())+ntpEpochOffset))
	binary.BigEndian.PutUint32(b[4:], uint32(uint64(t.Nanosecond())<<32/1e9))
}
