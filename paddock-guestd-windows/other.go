//go:build !windows

package main

import (
	"errors"
	"io"
	"time"
)

// The agent runs only in Windows guests; this lets the tests build on the Mac.
var errNotWindows = errors.New("the agent needs Windows")

type vsockListener struct{}

type vsockConn struct{ io.ReadWriteCloser }

func listen(uint32) (*vsockListener, error)                { return nil, errNotWindows }
func (*vsockListener) accept() (*vsockConn, uint32, error) { return nil, 0, errNotWindows }
func (*vsockConn) setReadTimeout(time.Duration)            {}
func state() []string                                      { return nil }
func run(string, bool, *answerer) response                 { return failed(errNotWindows.Error()) }
func setClock(time.Time) error                             { return errNotWindows }
func axtree(*answerer) response                            { return failed(errNotWindows.Error()) }
func printFocusedTree(_, _ io.Writer) int                  { return 1 }
