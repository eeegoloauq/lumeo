package library

import (
	"io/fs"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Disk is the filesystem a directory is on.
type Disk struct {
	Total uint64 `json:"total"`
	Free  uint64 `json:"free"`
}

func DiskUsage(path string) (Disk, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return Disk{}, err
	}
	var disk Disk
	if err := windows.GetDiskFreeSpaceEx(name, &disk.Free, &disk.Total, nil); err != nil {
		return Disk{}, err
	}
	return disk, nil
}

var getCompressedFileSize = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetCompressedFileSizeW")

// Allocated is what the files under path take on disk: a sparse file counts
// the clusters it has, not its length.
func Allocated(path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		size, err := allocated(path)
		if err != nil {
			return err
		}
		total += size
		return nil
	})
	return total, err
}

// INVALID_FILE_SIZE is also a valid low half, so the error tells them apart.
func allocated(path string) (int64, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	var high uint32
	low, _, err := getCompressedFileSize.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&high)))
	if uint32(low) == 0xFFFFFFFF && err != windows.ERROR_SUCCESS {
		return 0, err
	}
	return int64(high)<<32 | int64(uint32(low)), nil
}
