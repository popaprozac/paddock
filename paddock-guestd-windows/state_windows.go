package main

import (
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// state is what the host waits for before it hands the guest out: "network" once an adapter
// that is up has an IPv4 address (not link-local) and an IPv4 DNS server, and "desktop" once
// someone is signed in to the console with Explorer running in that session.
//
// shortcut: "desktop" doesn't check that the session is unlocked; the spike's image signs in
// automatically and never locks. Check WTSSessionInfoEx's lock state before images that can lock.
func state() []string {
	var lines []string
	if networkReady() {
		lines = append(lines, "network")
	}
	if desktop() {
		lines = append(lines, "desktop")
	}
	return lines
}

func networkReady() bool {
	size := uint32(16 * 1024)
	for attempt := 0; attempt < 3; attempt++ {
		buffer := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0]))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST, 0, first, &size)
		if err == windows.ERROR_BUFFER_OVERFLOW {
			continue
		}
		if err != nil {
			return false
		}
		for a := first; a != nil; a = a.Next {
			if a.OperStatus == windows.IfOperStatusUp && a.IfType != windows.IF_TYPE_SOFTWARE_LOOPBACK && hasIPv4(a) && hasIPv4DNS(a) {
				return true
			}
		}
		return false
	}
	return false
}

func hasIPv4(a *windows.IpAdapterAddresses) bool {
	for u := a.FirstUnicastAddress; u != nil; u = u.Next {
		if ip := u.Address.IP().To4(); ip != nil && !ip.IsLinkLocalUnicast() {
			return true
		}
	}
	return false
}

func hasIPv4DNS(a *windows.IpAdapterAddresses) bool {
	for d := a.FirstDnsServerAddress; d != nil; d = d.Next {
		if ip := d.Address.IP().To4(); ip != nil && !ip.IsLoopback() {
			return true
		}
	}
	return false
}

// desktop is whether an active session (the console, signed in) runs explorer.exe.
func desktop() bool {
	var sessions *windows.WTS_SESSION_INFO
	var count uint32
	if windows.WTSEnumerateSessions(0, 0, 1, &sessions, &count) != nil {
		return false
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(sessions)))
	active := map[uint32]bool{}
	for _, s := range unsafe.Slice(sessions, count) {
		if s.State == windows.WTSActive && s.SessionID != 0 {
			active[s.SessionID] = true
		}
	}
	if len(active) == 0 {
		return false
	}
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		if !strings.EqualFold(windows.UTF16ToString(entry.ExeFile[:]), "explorer.exe") {
			continue
		}
		var session uint32
		if windows.ProcessIdToSessionId(entry.ProcessID, &session) == nil && active[session] {
			return true
		}
	}
	return false
}
