package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The desktops whose shell process means the desktop has drawn and takes input, but for GNOME's
// (see drawn). Another desktop counts once its session has been up for settleSeconds.
var desktopShells = map[string]bool{
	"xfdesktop": true, "gnome-shell": true, "plasmashell": true, "cinnamon": true,
	"mate-panel": true, "budgie-panel": true, "lxqt-panel": true, "lxpanel": true,
}

const (
	settleSeconds = 5
	// How long a GNOME session may go without the shell's startup entry before its desktop counts
	// anyway, so that a GNOME that stops logging it still serves.
	gnomeBackstopSeconds = 60
	// The MESSAGE_ID of the "GNOME Shell started at" entry, which GNOME Shell logs once its startup
	// animation is over (startup-complete in main.js, added for GNOME's own smoke test in bug 728449).
	gnomeShellStarted = "f3ea493c22934e26811cd62abe8e203a"
)

var gnomeBackstopNote sync.Once

// desktop is whether the guest shows the account's desktop, ready for input: the screen's driver
// is up, the USB keyboard and pointer are there, and the account has an active, unlocked
// graphical session whose desktop has drawn. paddock waits for it on a desktop image before it
// saves a slot's state, as it waits for loginwindow on macOS.
func desktop() bool {
	if _, err := os.Stat("/dev/dri/card0"); err != nil {
		return false
	}
	devices, _ := os.ReadFile("/proc/bus/input/devices")
	if !hasKeyboardAndPointer(string(devices)) {
		return false
	}
	started, ok := graphicalSession("/run/systemd/sessions", "1000")
	if !ok {
		return false
	}
	uptime, _ := os.ReadFile("/proc/uptime")
	return drawn(runningShell("/proc", "1000"), string(uptime), started, gnomeStarted)
}

// drawn is whether the desktop whose shell is shell, "" when none of desktopShells runs, has drawn
// and takes input, in a session that started at started, in seconds since boot. GNOME Shell runs
// from the start of its session, but covers the screen with an actor that swallows input until its
// startup animation is over, so GNOME counts once its shell has logged that it started.
func drawn(shell, uptime string, started float64, gnomeStarted func() bool) bool {
	switch shell {
	case "":
		return settled(uptime, started, settleSeconds)
	case "gnome-shell":
		if gnomeStarted() {
			return true
		}
		if settled(uptime, started, gnomeBackstopSeconds) {
			gnomeBackstopNote.Do(func() {
				log.Printf("GNOME Shell logged no startup entry in %d s; counting its desktop up anyway", gnomeBackstopSeconds)
			})
			return true
		}
		return false
	default:
		return true
	}
}

// gnomeStarted is whether the account's GNOME Shell has logged, in this boot's journal, that it
// started.
func gnomeStarted() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "journalctl", "--boot", "--quiet", "--output=cat", "--lines=1",
		"_UID=1000", "MESSAGE_ID="+gnomeShellStarted).Output()
	return err == nil && len(bytes.TrimSpace(out)) > 0
}

// hasKeyboardAndPointer is whether /proc/bus/input/devices lists a keyboard and a pointer.
func hasKeyboardAndPointer(devices string) bool {
	keyboard, pointer := false, false
	for _, line := range strings.Split(devices, "\n") {
		handlers, ok := strings.CutPrefix(line, "H: Handlers=")
		if !ok {
			continue
		}
		for _, handler := range strings.Fields(handlers) {
			keyboard = keyboard || handler == "kbd"
			pointer = pointer || strings.HasPrefix(handler, "mouse")
		}
	}
	return keyboard && pointer
}

// graphicalSession finds, in systemd-logind's session files, an active and unlocked X11 or
// Wayland session of the user with uid, and returns when it started, in seconds since boot.
func graphicalSession(dir, uid string) (started float64, ok bool) {
	files, _ := os.ReadDir(dir)
	for _, file := range files {
		if strings.HasSuffix(file.Name(), ".ref") {
			continue
		}
		text, err := os.ReadFile(filepath.Join(dir, file.Name()))
		if err != nil {
			continue
		}
		fields := map[string]string{}
		for _, line := range strings.Split(string(text), "\n") {
			if key, value, found := strings.Cut(line, "="); found {
				fields[key] = value
			}
		}
		if fields["UID"] != uid || fields["CLASS"] != "user" || fields["STATE"] != "active" || fields["LOCKED_HINT"] == "1" {
			continue
		}
		if fields["TYPE"] != "x11" && fields["TYPE"] != "wayland" {
			continue
		}
		microseconds, _ := strconv.ParseFloat(fields["MONOTONIC"], 64)
		return microseconds / 1e6, true
	}
	return 0, false
}

// runningShell is the one of desktopShells that runs as the user with uid, from proc's processes,
// or "" when none does.
func runningShell(proc, uid string) string {
	entries, _ := os.ReadDir(proc)
	for _, entry := range entries {
		if _, err := strconv.Atoi(entry.Name()); err != nil {
			continue
		}
		comm, err := os.ReadFile(filepath.Join(proc, entry.Name(), "comm"))
		name := strings.TrimSpace(string(comm))
		if err != nil || !desktopShells[name] {
			continue
		}
		status, _ := os.ReadFile(filepath.Join(proc, entry.Name(), "status"))
		for _, line := range strings.Split(string(status), "\n") {
			if ids, found := strings.CutPrefix(line, "Uid:"); found {
				if real := strings.Fields(ids); len(real) > 0 && real[0] == uid {
					return name
				}
			}
		}
	}
	return ""
}

// settled is whether a session that started at started, in seconds since boot, has been up for
// seconds, by /proc/uptime's first field.
func settled(uptime string, started, seconds float64) bool {
	fields := strings.Fields(uptime)
	if len(fields) == 0 {
		return false
	}
	now, err := strconv.ParseFloat(fields[0], 64)
	return err == nil && now-started >= seconds
}
