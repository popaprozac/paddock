package main

import (
	"context"
	"errors"
	"net"
	"time"

	"github.com/miekg/dns"
)

// dnsHandler answers the guest's DNS queries to the gateway. A name the policy allows gets its
// IPv4 addresses from the host's resolver; every other name is refused. Nothing the guest asks
// is passed on to another server, so DNS can't carry data out.
type dnsHandler struct {
	policy *policy
	lookup func(ctx context.Context, host string) ([]net.IP, error)
	logf   func(format string, args ...any)
}

func (h *dnsHandler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	_ = w.WriteMsg(h.answer(r))
}

func (h *dnsHandler) answer(r *dns.Msg) *dns.Msg {
	m := new(dns.Msg)
	m.SetReply(r)
	m.RecursionAvailable = true
	if r.Opcode != dns.OpcodeQuery || len(r.Question) != 1 {
		m.Rcode = dns.RcodeRefused
		return m
	}
	q := r.Question[0]
	name := normalize(q.Name)
	if q.Qclass != dns.ClassINET || !h.policy.allows(name) {
		h.logf("deny dns %s: not on the list", name)
		m.Rcode = dns.RcodeRefused
		return m
	}
	if q.Qtype != dns.TypeA {
		return m // the guest's network is IPv4 only, so an allowed name has no other records
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ips, err := h.lookup(ctx, name)
	if err != nil {
		var dnsErr *net.DNSError
		if errors.As(err, &dnsErr) && dnsErr.IsNotFound {
			m.Rcode = dns.RcodeNameError
		} else {
			m.Rcode = dns.RcodeServerFailure
		}
		return m
	}
	for _, ip := range ips {
		if v4 := ip.To4(); v4 != nil {
			m.Answer = append(m.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
				A:   v4,
			})
		}
	}
	return m
}

// lookupIPv4 resolves a name through the host's own resolver.
func lookupIPv4(ctx context.Context, host string) ([]net.IP, error) {
	return net.DefaultResolver.LookupIP(ctx, "ip4", host)
}
