//go:build !windows

package torrent

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// openData opens a file of a torrent for reading and writing, creating it and
// its directories for a write. A file past its end is sparse here already.
func openData(path string, create bool) (*os.File, error) {
	flag := os.O_RDWR
	if create {
		flag |= os.O_CREATE
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, err
		}
	}
	f, err := os.OpenFile(path, flag, 0o600)
	if errors.Is(err, fs.ErrPermission) {
		// Earlier versions left a finished file read-only.
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, err
		}
		f, err = os.OpenFile(path, flag, 0o600)
	}
	return f, err
}
