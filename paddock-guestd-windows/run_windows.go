package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Output lines longer than this are split, so every answer line stays well under the 64 KB the
// host's reader accepts even after JSON escaping.
const outputChunk = 8 * 1024

// starting serializes process creation: a child inherits every inheritable handle, so a pipe's
// write end is inheritable only while its own process starts, and two starts at once would hand
// each other's pipes on and keep them open.
var starting sync.Mutex

// run runs `command` through cmd.exe, as the account signed in at the console, on its desktop, or
// as SYSTEM with root, and streams its output and error as lines.
func run(command string, root bool, out *answerer) response {
	system, err := windows.GetSystemDirectory()
	if err != nil {
		return failed("can't start the command: " + err.Error())
	}
	reader, process, err := startPiped(system+`\cmd.exe`, `cmd.exe /d /s /c "`+command+`"`, root)
	if err != nil {
		return failed("can't start the command: " + err.Error())
	}
	defer windows.CloseHandle(process)
	streamLines(reader, out)
	reader.Close()
	return exited(int(int32(wait(process))))
}

// startPiped starts the program at appPath with the command line commandLine, as start does,
// and returns a pipe that reads its output and error, and the process.
func startPiped(appPath, commandLine string, root bool) (*os.File, windows.Handle, error) {
	var r, w windows.Handle
	sa := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{}))}
	if err := windows.CreatePipe(&r, &w, &sa, 0); err != nil {
		return nil, 0, err
	}
	process, err := start(appPath, commandLine, root, w)
	if err != nil {
		windows.CloseHandle(r)
		return nil, 0, err
	}
	return os.NewFile(uintptr(r), "output"), process, nil
}

// wait waits for `process` to end and gives its exit code.
func wait(process windows.Handle) uint32 {
	windows.WaitForSingleObject(process, windows.INFINITE)
	var code uint32
	windows.GetExitCodeProcess(process, &code)
	return code
}

// start starts the program at appPath with the command line commandLine, as the account signed
// in at the console, on its desktop, or as SYSTEM with root, with its output and error going to
// `w`, which it closes, and returns the process.
func start(appPath, commandLine string, root bool, w windows.Handle) (windows.Handle, error) {
	app, err := windows.UTF16PtrFromString(appPath)
	if err != nil {
		windows.CloseHandle(w)
		return 0, err
	}
	line, err := windows.UTF16PtrFromString(commandLine)
	if err != nil {
		windows.CloseHandle(w)
		return 0, fmt.Errorf("the command has a NUL character")
	}
	si := windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfo{})), Flags: windows.STARTF_USESTDHANDLES, StdOutput: w, StdErr: w}
	var pi windows.ProcessInformation

	starting.Lock()
	defer starting.Unlock()
	defer windows.CloseHandle(w)
	windows.SetHandleInformation(w, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT)
	if root {
		err = windows.CreateProcess(app, line, nil, nil, true, windows.CREATE_NO_WINDOW, nil, nil, &si, &pi)
	} else {
		err = startAsConsoleUser(app, line, &si, &pi)
	}
	if err != nil {
		return 0, err
	}
	windows.CloseHandle(pi.Thread)
	return pi.Process, nil
}

// startAsConsoleUser starts the process as the account signed in at the console, with its
// environment and profile folder, on its interactive desktop, so what it opens shows there.
func startAsConsoleUser(app, line *uint16, si *windows.StartupInfo, pi *windows.ProcessInformation) error {
	token, err := consoleUserToken()
	if err != nil {
		return err
	}
	defer token.Close()
	var env *uint16
	if err := windows.CreateEnvironmentBlock(&env, token, false); err != nil {
		return fmt.Errorf("can't read the account's environment: %w", err)
	}
	defer windows.DestroyEnvironmentBlock(env)
	var dir *uint16
	if home, err := token.GetUserProfileDirectory(); err == nil {
		dir, _ = windows.UTF16PtrFromString(home)
	}
	si.Desktop, _ = windows.UTF16PtrFromString(`winsta0\default`)
	return windows.CreateProcessAsUser(token, app, line, nil, nil, true,
		windows.CREATE_NO_WINDOW|windows.CREATE_UNICODE_ENVIRONMENT, env, dir, si, pi)
}

// consoleUserToken is the token of the account signed in at the console, which commands and
// file transfers run as.
func consoleUserToken() (windows.Token, error) {
	var token windows.Token
	if err := windows.WTSQueryUserToken(windows.WTSGetActiveConsoleSessionId(), &token); err != nil {
		return 0, fmt.Errorf("no one is signed in at the console: %w", err)
	}
	// An administrator signs in with a filtered token and an elevated one linked to it, as UAC
	// does. Commands get the elevated one, as a Linux guest's workload account has sudo without a
	// password; a standard account has no linked token and keeps its own.
	if !token.IsElevated() {
		if linked, err := token.GetLinkedToken(); err == nil {
			token.Close()
			token = linked
		}
	}
	return token, nil
}

// streamLines sends what `r` gives as lines without their CR LF, splitting any over outputChunk,
// and sends all the lines one read brings at once.
func streamLines(r io.Reader, out *answerer) {
	buf := make([]byte, 64*1024)
	var pending []byte
	for {
		n, err := r.Read(buf)
		pending = append(pending, buf[:n]...)
		var lines []response
		for {
			i := bytes.IndexByte(pending, '\n')
			if i >= 0 && i <= outputChunk {
				lines = append(lines, output(bytes.TrimSuffix(pending[:i], []byte("\r"))))
				pending = pending[i+1:]
			} else if len(pending) > outputChunk {
				lines = append(lines, output(pending[:outputChunk]))
				pending = pending[outputChunk:]
			} else {
				break
			}
		}
		out.send(lines...)
		if err != nil {
			if len(pending) > 0 {
				out.send(output(bytes.TrimSuffix(pending, []byte("\r"))))
			}
			return
		}
	}
}

var procSetSystemTime = windows.NewLazySystemDLL("kernel32.dll").NewProc("SetSystemTime")

// setClock sets the system clock, which SYSTEM may do, to `t`.
func setClock(t time.Time) error {
	u := t.UTC()
	st := windows.Systemtime{Year: uint16(u.Year()), Month: uint16(u.Month()), DayOfWeek: uint16(u.Weekday()),
		Day: uint16(u.Day()), Hour: uint16(u.Hour()), Minute: uint16(u.Minute()), Second: uint16(u.Second()),
		Milliseconds: uint16(u.Nanosecond() / 1e6)}
	if r, _, e := procSetSystemTime.Call(uintptr(unsafe.Pointer(&st))); r == 0 {
		return e
	}
	return nil
}
