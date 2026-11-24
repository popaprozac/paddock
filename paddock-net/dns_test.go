package main

import (
	"context"
	"net"
	"testing"

	"github.com/miekg/dns"
)

func testDNS(t *testing.T) (*dnsHandler, *[]string) {
	t.Helper()
	p, err := newPolicy([]string{"github.com", "*.example.org"})
	if err != nil {
		t.Fatal(err)
	}
	var looked []string
	return &dnsHandler{
		policy: holding(p),
		lookup: func(_ context.Context, host string) ([]net.IP, error) {
			looked = append(looked, host)
			if host == "missing.example.org" {
				return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
			}
			return []net.IP{net.ParseIP("140.82.112.3"), net.ParseIP("2001:db8::1")}, nil
		},
		logf: t.Logf,
	}, &looked
}

func query(name string, qtype uint16) *dns.Msg {
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), qtype)
	return m
}

func TestDNSAnswersAnAllowedNameWithIPv4Only(t *testing.T) {
	h, _ := testDNS(t)
	m := h.answer(query("GitHub.com", dns.TypeA))
	if m.Rcode != dns.RcodeSuccess || len(m.Answer) != 1 {
		t.Fatalf("got rcode %d with %d answers, want one A record", m.Rcode, len(m.Answer))
	}
	if a, ok := m.Answer[0].(*dns.A); !ok || !a.A.Equal(net.ParseIP("140.82.112.3")) {
		t.Errorf("answer %v, want 140.82.112.3", m.Answer[0])
	}
}

func TestDNSDeniesNamesNotOnTheListWithoutAskingTheHost(t *testing.T) {
	h, looked := testDNS(t)
	for _, qtype := range []uint16{dns.TypeA, dns.TypeAAAA, dns.TypeTXT, dns.TypeHTTPS} {
		m := h.answer(query("secret.attacker.example", qtype))
		if m.Rcode != dns.RcodeNameError || len(m.Answer) != 0 {
			t.Errorf("type %d: rcode %d with %d answers, want no such name", qtype, m.Rcode, len(m.Answer))
		}
		if len(m.Ns) != 1 || m.Ns[0].Header().Ttl != 0 || m.Ns[0].(*dns.SOA).Minttl != 0 {
			t.Errorf("type %d: authority %v, want one SOA that says not to cache", qtype, m.Ns)
		}
	}
	if len(*looked) != 0 {
		t.Errorf("asked the host about %v", *looked)
	}
}

func TestDNSGivesAllowedNamesNoOtherRecords(t *testing.T) {
	h, looked := testDNS(t)
	m := h.answer(query("github.com", dns.TypeAAAA))
	if m.Rcode != dns.RcodeSuccess || len(m.Answer) != 0 || len(*looked) != 0 {
		t.Errorf("AAAA: rcode %d, %d answers, lookups %v; want an empty answer", m.Rcode, len(m.Answer), *looked)
	}
}

func TestDNSSaysNoSuchNameWhenTheHostFindsNone(t *testing.T) {
	h, _ := testDNS(t)
	if m := h.answer(query("missing.example.org", dns.TypeA)); m.Rcode != dns.RcodeNameError {
		t.Errorf("rcode %d, want name error", m.Rcode)
	}
}
