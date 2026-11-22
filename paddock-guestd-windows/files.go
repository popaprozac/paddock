package main

import "strings"

const (
	fileChunk   = 1 << 20
	maxFileSize = int64(4) << 30
)

// isFileName is whether `name` is one plain file name that Windows stores as given. That rules
// out path separators, a drive's or stream's colon, wildcards and control characters, and a
// leading dot, as on Linux. It also rules out a trailing dot or space, which Windows drops, and a
// device name such as NUL or COM1, with or without an extension, which Windows opens as the
// device.
func isFileName(name string) bool {
	if name == "" || len(name) > 255 || name[0] == '.' || strings.ContainsAny(name, `<>:"/\|?*`) ||
		strings.HasSuffix(name, ".") || strings.HasSuffix(name, " ") {
		return false
	}
	for _, r := range name {
		if r < 32 {
			return false
		}
	}
	base, _, _ := strings.Cut(strings.ToUpper(name), ".")
	base = strings.TrimRight(base, " ")
	switch base {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$":
		return false
	}
	if strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT") {
		switch base[3:] {
		case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³":
			return false
		}
	}
	return true
}
