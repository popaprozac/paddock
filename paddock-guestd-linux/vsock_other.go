//go:build !linux

package main

import (
	"errors"
	"os"
)

// The agent runs only in Linux guests; this lets the tests build on the Mac.
var errNotLinux = errors.New("vsock needs Linux")

func listen(uint32) (int, error)           { return -1, errNotLinux }
func accept(int) (*os.File, uint32, error) { return nil, 0, errNotLinux }
