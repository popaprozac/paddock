package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"

	"golang.org/x/sys/windows"
)

// put and get move files between the host and the paddock folder in the profile of the account
// signed in at the console. The agent opens each file while impersonating that account, never as
// SYSTEM, so a link planted in the folder reaches only what the account could reach anyway.
// Files and the folder take the profile's permissions: the account, SYSTEM and administrators.

// put stores the `size` bytes that follow the request as `name`.
func put(name string, size int64, in io.Reader) response {
	f, err := openAsConsoleUser(func(folder string) (*os.File, error) {
		if err := os.MkdirAll(folder, 0o700); err != nil {
			return nil, err
		}
		return os.OpenFile(filepath.Join(folder, name), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	})
	if err != nil {
		return failed(fmt.Sprintf("can't store '%s': %v", name, err))
	}
	copied, err := io.CopyN(f, in, size)
	closed := f.Close()
	// The file's write failing, as on a full disk, is the guest's, not a short upload.
	if failure := (*fs.PathError)(nil); errors.As(err, &failure) && failure.Op == "write" {
		return failed(fmt.Sprintf("can't store '%s' in the guest: %v", name, failure.Err))
	}
	if copied < size {
		return failed(fmt.Sprintf("'%s' stopped after %d of %d bytes", name, copied, size))
	}
	if closed != nil {
		return failed(fmt.Sprintf("can't store '%s' in the guest: %v", name, closed))
	}
	return exited(0)
}

// get sends `name` as chunks: a {"chunk":n} line and n bytes each.
func get(name string, out *answerer) response {
	f, err := openAsConsoleUser(func(folder string) (*os.File, error) {
		return os.Open(filepath.Join(folder, name))
	})
	if err != nil {
		return failed(fmt.Sprintf("can't read '%s': %v", name, err))
	}
	defer f.Close()
	buf := make([]byte, fileChunk)
	for !out.gone {
		n, err := f.Read(buf)
		if n > 0 {
			out.sendChunk(buf[:n])
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return failed(fmt.Sprintf("can't read '%s' in the guest: %v", name, err))
		}
	}
	return exited(0)
}

var procImpersonateLoggedOnUser = windows.NewLazySystemDLL("advapi32.dll").NewProc("ImpersonateLoggedOnUser")

// openAsConsoleUser calls `open` with the console account's paddock folder while this thread
// impersonates the account, so Windows checks the files it opens against the account's access.
func openAsConsoleUser(open func(folder string) (*os.File, error)) (*os.File, error) {
	token, err := consoleUserToken()
	if err != nil {
		return nil, err
	}
	defer token.Close()
	home, err := token.GetUserProfileDirectory()
	if err != nil {
		return nil, fmt.Errorf("can't find the account's profile folder: %w", err)
	}
	// Impersonation belongs to a thread, so this goroutine keeps its thread until it reverts.
	// If reverting fails, the thread stays locked and Go ends it with the goroutine, rather than
	// hand a thread still acting as the account to other work.
	runtime.LockOSThread()
	if r, _, e := procImpersonateLoggedOnUser.Call(uintptr(token)); r == 0 {
		runtime.UnlockOSThread()
		return nil, fmt.Errorf("can't act as the account: %w", e)
	}
	f, err := open(filepath.Join(home, "paddock"))
	if reverted := windows.RevertToSelf(); reverted != nil {
		if f != nil {
			f.Close()
		}
		return nil, fmt.Errorf("can't stop acting as the account: %w", reverted)
	}
	runtime.UnlockOSThread()
	return f, err
}
