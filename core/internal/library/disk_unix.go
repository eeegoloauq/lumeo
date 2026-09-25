//go:build aix || darwin || dragonfly || freebsd || linux || netbsd || openbsd

package library

import (
	"io/fs"
	"path/filepath"
	"syscall"
)

// Disk is the filesystem a directory is on.
type Disk struct {
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

func DiskUsage(path string) (Disk, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return Disk{}, err
	}
	return Disk{
		Total: uint64(stat.Blocks) * uint64(stat.Bsize),
		Free:  uint64(stat.Bavail) * uint64(stat.Bsize),
	}, nil
}

// Allocated is what the files under path take on disk: a sparse file counts
// the blocks it has, not its length.
func Allocated(path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			total += int64(stat.Blocks) * 512
		} else {
			total += info.Size()
		}
		return nil
	})
	return total, err
}
