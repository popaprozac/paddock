package main

import (
	"strings"
	"testing"
)

func TestFileNamesAreOnePlainNameWindowsKeeps(t *testing.T) {
	for _, name := range []string{"in.bundle", "out.bundle", "report 2.txt", "a", "COM10", "LPT", "console.log",
		"nul-free.txt", "résumé.pdf", strings.Repeat("a", 255)} {
		if !isFileName(name) {
			t.Errorf("refused %q", name)
		}
	}
	for _, name := range []string{"", ".", "..", ".hidden", `a\b`, "a/b", `C:x`, "a:stream", "a*", "a?", `a"b`,
		"a<b", "a>b", "a|b", "tab\tname", "dot.", "space ", "NUL", "nul", "nul.txt", "NUL .txt", "CON", "prn.log",
		"AUX", "COM1", "com9.txt", "LPT0", "COM¹", "CONIN$", "conout$.txt", strings.Repeat("a", 256)} {
		if isFileName(name) {
			t.Errorf("allowed %q", name)
		}
	}
}
