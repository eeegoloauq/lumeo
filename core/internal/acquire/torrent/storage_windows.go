package torrent

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// openData opens a file of a torrent for reading and writing, creating it and
// its directories for a write. A file it creates is made sparse: NTFS would
// otherwise zero-fill everything before a write past the end, and the last
// piece of a film is asked for first.
func openData(path string, create bool) (*os.File, error) {
	if create {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
		if err == nil {
			// Best effort: FAT32 and exFAT have no sparse files, and the data
			// is the same either way.
			var n uint32
			_ = windows.DeviceIoControl(windows.Handle(f.Fd()), windows.FSCTL_SET_SPARSE, nil, 0, nil, 0, &n, nil)
			return f, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return nil, err
		}
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0o600)
	if errors.Is(err, fs.ErrPermission) {
		// Earlier versions left a finished file read-only.
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, err
		}
		f, err = os.OpenFile(path, os.O_RDWR, 0o600)
	}
	return f, err
}
