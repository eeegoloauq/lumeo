//go:build unix

package main

import (
	"os"
	"path/filepath"
	"strconv"
)

// logFile is the path of the regular file f writes to, or "" when it is
// anything else: the journal's socket, a terminal, a pipe.
func logFile(f *os.File) string {
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	// Linux names what a descriptor points at; elsewhere there is no name to
	// give, and a file deleted since has none either, which SameFile catches.
	path, err := os.Readlink("/proc/self/fd/" + strconv.FormatUint(uint64(f.Fd()), 10))
	if err != nil || !filepath.IsAbs(path) {
		return ""
	}
	if named, err := os.Stat(path); err != nil || !os.SameFile(named, info) {
		return ""
	}
	return path
}
