package main

import (
	"os"
	"strings"

	"golang.org/x/sys/windows"
)

// logFile is the path of the regular file f writes to, or "" when it is
// anything else: a console, a pipe. The app hands the core core.log as its
// stderr, since a GUI process has none of its own.
func logFile(f *os.File) string {
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	buf := make([]uint16, windows.MAX_LONG_PATH)
	// Flags 0: the normalised name, with a drive letter.
	n, err := windows.GetFinalPathNameByHandle(windows.Handle(f.Fd()), &buf[0], uint32(len(buf)), 0)
	if err != nil || n == 0 || int(n) >= len(buf) {
		return ""
	}
	path := windows.UTF16ToString(buf[:n])
	// The name comes in its long form, \\?\C:\… or \\?\UNC\server\…, which
	// is not what a person reads or pastes.
	if rest, ok := strings.CutPrefix(path, `\\?\UNC\`); ok {
		return `\\` + rest
	}
	return strings.TrimPrefix(path, `\\?\`)
}
