package main

import (
	"encoding/binary"
	"log"
	"net"
	"os/exec"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// state is what the host waits for before it hands the guest out: "network" once an adapter
// that is up has an IPv4 address (not link-local) and an IPv4 DNS server and its traffic gets
// through (see networkReady), and "desktop" once someone is signed in to the console with
// Explorer running in that session.
//
// shortcut: "desktop" doesn't check that the session is unlocked; a Windows image signs in
// automatically and never locks (docs/golden-images.md). Check WTSSessionInfoEx's lock state
// before images that can lock.
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

// networkReady is whether an adapter that is up has an IPv4 address and an IPv4 DNS server, and
// its traffic gets through: its IPv4 gateway answers a ping, or it received something during the
// ping, as on a network whose gateway ignores pings. After Virtualization.framework restores a
// saved state, virtio-win's NetKVM sends but receives nothing until the adapter restarts, so an
// adapter that received nothing during an unanswered ping is restarted.
func networkReady() bool {
	a, ok := ipv4Adapter()
	if !ok {
		return false
	}
	if a.gateway == nil {
		return true // nothing to check it against
	}
	before := received(a.index)
	if ping(a.gateway, 500*time.Millisecond) || received(a.index) > before {
		return true
	}
	restart(a.name)
	return false
}

type adapter struct {
	index   uint32
	name    string
	gateway net.IP // nil without an IPv4 gateway
}

// ipv4Adapter is the first adapter that is up, isn't loopback, and has an IPv4 address and an
// IPv4 DNS server.
func ipv4Adapter() (adapter, bool) {
	size := uint32(16 * 1024)
	for attempt := 0; attempt < 3; attempt++ {
		buffer := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0]))
		flags := uint32(windows.GAA_FLAG_SKIP_ANYCAST | windows.GAA_FLAG_SKIP_MULTICAST | windows.GAA_FLAG_INCLUDE_GATEWAYS)
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, first, &size)
		if err == windows.ERROR_BUFFER_OVERFLOW {
			continue
		}
		if err != nil {
			return adapter{}, false
		}
		for a := first; a != nil; a = a.Next {
			if a.OperStatus != windows.IfOperStatusUp || a.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK || !hasIPv4(a) || !hasIPv4DNS(a) {
				continue
			}
			found := adapter{index: a.IfIndex, name: windows.UTF16PtrToString(a.FriendlyName)}
			for g := a.FirstGatewayAddress; g != nil; g = g.Next {
				if ip := g.Address.IP().To4(); ip != nil {
					found.gateway = ip
					break
				}
			}
			return found, true
		}
		return adapter{}, false
	}
	return adapter{}, false
}

// received is how many packets the interface has received.
func received(index uint32) uint64 {
	row := windows.MibIfRow2{InterfaceIndex: index}
	if windows.GetIfEntry2Ex(0, &row) != nil { // MibIfEntryNormal
		return 0
	}
	return row.InUcastPkts + row.InNUcastPkts
}

var (
	iphlpapi        = windows.NewLazySystemDLL("iphlpapi.dll")
	procIcmpCreate  = iphlpapi.NewProc("IcmpCreateFile")
	procIcmpSend    = iphlpapi.NewProc("IcmpSendEcho")
	procIcmpClose   = iphlpapi.NewProc("IcmpCloseHandle")
	restarting      sync.Mutex
	lastRestart     time.Time
	restartInterval = 15 * time.Second
)

// ping is whether `ip` answers an ICMP echo within `timeout`.
func ping(ip net.IP, timeout time.Duration) bool {
	h, _, _ := procIcmpCreate.Call()
	if h == uintptr(windows.InvalidHandle) {
		return false
	}
	defer procIcmpClose.Call(h)
	data := []byte("paddock")
	reply := make([]byte, 256) // an ICMP_ECHO_REPLY and the echoed data
	n, _, _ := procIcmpSend.Call(h, uintptr(binary.LittleEndian.Uint32(ip.To4())), uintptr(unsafe.Pointer(&data[0])),
		uintptr(len(data)), 0, uintptr(unsafe.Pointer(&reply[0])), uintptr(len(reply)), uintptr(timeout/time.Millisecond))
	return n > 0 && binary.LittleEndian.Uint32(reply[4:]) == 0 // Status IP_SUCCESS
}

// restart disables and enables the adapter called `name`, at most once every restartInterval.
func restart(name string) {
	restarting.Lock()
	defer restarting.Unlock()
	if time.Since(lastRestart) < restartInterval {
		return
	}
	lastRestart = time.Now()
	log.Printf("paddock-guestd: '%s' receives nothing; restarting it", name)
	for _, state := range []string{"disabled", "enabled"} {
		exec.Command("netsh", "interface", "set", "interface", "name="+name, "admin="+state).Run()
	}
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
