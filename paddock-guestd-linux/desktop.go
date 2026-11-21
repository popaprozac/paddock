package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The desktops whose shell process means the desktop has drawn. Another desktop counts once its
// session has been up for settleSeconds.
var desktopShells = map[string]bool{
	"xfdesktop": true, "gnome-shell": true, "plasmashell": true, "cinnamon": true,
	"mate-panel": true, "budgie-panel": true, "lxqt-panel": true, "lxpanel": true,
}

const settleSeconds = 5

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
	if shellRuns("/proc", "1000") {
		return true
	}
	uptime, _ := os.ReadFile("/proc/uptime")
	return settled(string(uptime), started)
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

// shellRuns is whether one of desktopShells runs as the user with uid, from proc's processes.
func shellRuns(proc, uid string) bool {
	entries, _ := os.ReadDir(proc)
	for _, entry := range entries {
		if _, err := strconv.Atoi(entry.Name()); err != nil {
			continue
		}
		comm, err := os.ReadFile(filepath.Join(proc, entry.Name(), "comm"))
		if err != nil || !desktopShells[strings.TrimSpace(string(comm))] {
			continue
		}
		status, _ := os.ReadFile(filepath.Join(proc, entry.Name(), "status"))
		for _, line := range strings.Split(string(status), "\n") {
			if ids, found := strings.CutPrefix(line, "Uid:"); found {
				if real := strings.Fields(ids); len(real) > 0 && real[0] == uid {
					return true
				}
			}
		}
	}
	return false
}

// settled is whether a session that started at started, in seconds since boot, has been up for
// settleSeconds, by /proc/uptime's first field.
func settled(uptime string, started float64) bool {
	fields := strings.Fields(uptime)
	if len(fields) == 0 {
		return false
	}
	now, err := strconv.ParseFloat(fields[0], 64)
	return err == nil && now-started >= settleSeconds
}
