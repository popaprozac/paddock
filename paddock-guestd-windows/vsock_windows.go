package main

import (
	"errors"
	"io"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// AF_VSOCK through viosock's Winsock provider (virtio-win's viosock driver and viosockwspsvc).
const afVsock = 40

// sockaddrVM is viosock's SOCKADDR_VM: family, reserved, port, CID, padding to 16 bytes.
type sockaddrVM struct {
	family   uint16
	reserved uint16
	port     uint32
	cid      uint32
	zero     [4]uint8
}

var (
	ws2      = windows.NewLazySystemDLL("ws2_32.dll")
	procBind = ws2.NewProc("bind")
	procAcc  = ws2.NewProc("accept")
	procRecv = ws2.NewProc("recv")
	procSend = ws2.NewProc("send")
)

const socketError = ^uintptr(0) // INVALID_SOCKET, and SOCKET_ERROR as an unsigned result

type vsockListener struct{ s windows.Handle }

// listen opens a vsock socket listening on `port`, from any CID. x/sys/windows's Bind and Accept
// know only IP and Unix addresses, so those two go to ws2_32 directly.
func listen(port uint32) (*vsockListener, error) {
	var data windows.WSAData
	if err := windows.WSAStartup(uint32(0x0202), &data); err != nil {
		return nil, err
	}
	s, err := windows.Socket(afVsock, windows.SOCK_STREAM, 0)
	if err != nil {
		return nil, err
	}
	noInherit(s)
	address := sockaddrVM{family: afVsock, port: port, cid: 0xFFFFFFFF}
	if r, _, e := procBind.Call(uintptr(s), uintptr(unsafe.Pointer(&address)), unsafe.Sizeof(address)); r != 0 {
		windows.Closesocket(s)
		return nil, wsaError(e)
	}
	if err := windows.Listen(s, 16); err != nil {
		windows.Closesocket(s)
		return nil, err
	}
	return &vsockListener{s}, nil
}

// accept waits for the next connection and returns it with its peer's CID.
func (l *vsockListener) accept() (*vsockConn, uint32, error) {
	var peer sockaddrVM
	size := int32(unsafe.Sizeof(peer))
	r, _, e := procAcc.Call(uintptr(l.s), uintptr(unsafe.Pointer(&peer)), uintptr(unsafe.Pointer(&size)))
	if r == socketError {
		return nil, 0, wsaError(e)
	}
	c := windows.Handle(r)
	noInherit(c)
	return &vsockConn{c}, peer.cid, nil
}

// noInherit keeps a socket out of the commands the agent starts: sockets are inheritable, and a
// command holding a host connection would keep it open after the agent closes it.
func noInherit(s windows.Handle) {
	windows.SetHandleInformation(s, windows.HANDLE_FLAG_INHERIT, 0)
}

// vsockConn is one accepted connection, read and written with recv and send.
type vsockConn struct{ s windows.Handle }

func (c *vsockConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	r, _, e := procRecv.Call(uintptr(c.s), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)), 0)
	switch {
	case r == socketError:
		return 0, wsaError(e)
	case r == 0:
		return 0, io.EOF
	}
	return int(r), nil
}

func (c *vsockConn) Write(p []byte) (int, error) {
	written := 0
	for written < len(p) {
		r, _, e := procSend.Call(uintptr(c.s), uintptr(unsafe.Pointer(&p[written])), uintptr(len(p)-written), 0)
		if r == socketError {
			return written, wsaError(e)
		}
		written += int(r)
	}
	return written, nil
}

func (c *vsockConn) Close() error { return windows.Closesocket(c.s) }

// setReadTimeout makes a recv that waits longer than `d` fail, as the other agents' read deadlines do.
func (c *vsockConn) setReadTimeout(d time.Duration) {
	ms := uint32(d / time.Millisecond)
	windows.Setsockopt(c.s, windows.SOL_SOCKET, windows.SO_RCVTIMEO, (*byte)(unsafe.Pointer(&ms)), 4)
}

// wsaError is the Winsock error a ws2_32 call left (WSAGetLastError is GetLastError, which
// Proc.Call captures), or a generic one if it left none.
func wsaError(e error) error {
	if errno, ok := e.(syscall.Errno); ok && errno != 0 {
		return errno
	}
	return errors.New("winsock call failed")
}
