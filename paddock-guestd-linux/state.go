package main

import (
	"net"
	"os"
	"strings"
)

// state is what the host waits for before it hands the guest out: "network" once an interface
// other than loopback has an IPv4 address and the guest an IPv4 DNS server.
func state() []string {
	if hasIPv4Address() && len(ipv4Nameservers(resolvers())) > 0 {
		return []string{"network"}
	}
	return nil
}

func hasIPv4Address() bool {
	interfaces, _ := net.Interfaces()
	for _, i := range interfaces {
		if i.Flags&net.FlagLoopback != 0 || i.Flags&net.FlagUp == 0 {
			continue
		}
		addresses, _ := i.Addrs()
		for _, address := range addresses {
			if ip, ok := address.(*net.IPNet); ok && ip.IP.To4() != nil && !ip.IP.IsLinkLocalUnicast() {
				return true
			}
		}
	}
	return false
}

// resolvers is the guest's resolv.conf: systemd-resolved's list of the servers it forwards to
// when it runs, since /etc/resolv.conf then names only its own stub, else /etc/resolv.conf.
func resolvers() string {
	for _, path := range []string{"/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"} {
		if text, err := os.ReadFile(path); err == nil {
			return string(text)
		}
	}
	return ""
}

// ipv4Nameservers is the IPv4 servers a resolv.conf names, leaving out loopback ones such as
// systemd-resolved's stub.
func ipv4Nameservers(resolvConf string) []string {
	var servers []string
	for _, line := range strings.Split(resolvConf, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[0] != "nameserver" {
			continue
		}
		if ip := net.ParseIP(fields[1]); ip != nil && ip.To4() != nil && !ip.IsLoopback() {
			servers = append(servers, fields[1])
		}
	}
	return servers
}
