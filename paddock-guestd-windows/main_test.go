package main

import "testing"

// The agent serves only the host: a process in the guest reaches it through vsock loopback, from
// the guest's own address or the local one, and the hypervisor's and the wildcard are no host.
func TestOnlyTheHostsVsockAddressIsServed(t *testing.T) {
	for cid, want := range map[uint32]bool{2: true, 0: false, 1: false, 3: false, 0xFFFFFFFF: false} {
		if fromHost(cid) != want {
			t.Errorf("fromHost(%d) = %v, want %v", cid, !want, want)
		}
	}
}
