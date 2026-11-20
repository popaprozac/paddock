package main

import (
	"os"
	"syscall"
	"unsafe"
)

const afVsock = 40

// sockaddrVM is Linux's struct sockaddr_vm.
type sockaddrVM struct {
	family   uint16
	reserved uint16
	port     uint32
	cid      uint32
	flags    uint8
	zero     [3]uint8
}

// listen opens a vsock socket listening on `port`, from any CID.
func listen(port uint32) (int, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	address := sockaddrVM{family: afVsock, port: port, cid: 0xFFFFFFFF}
	if _, _, e := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&address)), unsafe.Sizeof(address)); e != 0 {
		syscall.Close(fd)
		return -1, e
	}
	if err := syscall.Listen(fd, 16); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	return fd, nil
}

// accept waits for the next connection and returns it with its peer's CID. Go's syscall.Accept
// doesn't know vsock addresses: it closes the connection and fails with EAFNOSUPPORT. The
// connection is non-blocking, so the os.File it becomes takes read deadlines.
func accept(fd int) (*os.File, uint32, error) {
	for {
		var peer sockaddrVM
		size := uint32(unsafe.Sizeof(peer))
		c, _, e := syscall.Syscall6(syscall.SYS_ACCEPT4, uintptr(fd), uintptr(unsafe.Pointer(&peer)),
			uintptr(unsafe.Pointer(&size)), syscall.SOCK_NONBLOCK|syscall.SOCK_CLOEXEC, 0, 0)
		if e == syscall.EINTR {
			continue
		}
		if e != 0 {
			return nil, 0, e
		}
		return os.NewFile(c, "vsock"), peer.cid, nil
	}
}
