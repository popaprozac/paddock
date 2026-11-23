package main

import (
	"bytes"
	stdlog "log"
	"testing"
	"time"

	"golang.org/x/time/rate"
)

func TestTheLogKeepsToItsLimitAndSaysWhatItDropped(t *testing.T) {
	var out bytes.Buffer
	logf := limitedLog(stdlog.New(&out, "", 0), rate.NewLimiter(rate.Every(50*time.Millisecond), 3))
	for i := range 10 {
		logf("deny %d", i)
	}
	time.Sleep(60 * time.Millisecond)
	logf("allow github.com:443")
	want := "deny 0\ndeny 1\ndeny 2\ndropped 7 lines, over 20 a second\nallow github.com:443\n"
	if got := out.String(); got != want {
		t.Errorf("logged %q, want %q", got, want)
	}
}
