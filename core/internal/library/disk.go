package library

import "path/filepath"

// Disk is the filesystem a directory is on.
type Disk struct {
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

// DiskUsage measures the filesystem path is on, or will be on once it is
// made: the download directory does not exist until the first download.
func DiskUsage(path string) (Disk, error) {
	for {
		disk, err := diskUsage(path)
		parent := filepath.Dir(path)
		if err == nil || parent == path {
			return disk, err
		}
		path = parent
	}
}
