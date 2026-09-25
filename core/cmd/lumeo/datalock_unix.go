//go:build unix

package main

import (
	"errors"
	"os"
	"syscall"
)

// tryLock takes an exclusive lock on f without waiting; false is a lock
// another process holds.
func tryLock(f *os.File) (bool, error) {
	err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return false, nil
	}
	return err == nil, err
}
