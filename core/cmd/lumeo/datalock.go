package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

// errDataDirBusy is a data directory another core holds.
var errDataDirBusy = errors.New("data directory is in use by another core")

// lockDataDir takes the data directory for this process alone: two cores on
// one directory resume the same downloads into the same files. The kernel
// drops the lock when the process ends, however it ends.
//
// A core the app started waits for the lock instead of failing: the usual
// holder is the core of a window just closed, still finishing its downloads,
// and the reopened app's core has to come up once that one is gone. A core
// started by hand is told at once.
func lockDataDir(ctx context.Context, dir string, wait bool, log *slog.Logger) (*os.File, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create data directory %q: %w", dir, err)
	}
	f, err := os.OpenFile(filepath.Join(dir, "lumeo.lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open data directory lock: %w", err)
	}
	logged := false
	for {
		locked, err := tryLock(f)
		if err != nil {
			f.Close()
			return nil, fmt.Errorf("lock data directory %q: %w", dir, err)
		}
		if locked {
			return f, nil
		}
		if !wait {
			f.Close()
			return nil, fmt.Errorf("%w: %s", errDataDirBusy, dir)
		}
		if !logged {
			log.Info("data directory in use, waiting for the other core to stop", "dir", dir)
			logged = true
		}
		select {
		case <-ctx.Done():
			f.Close()
			return nil, ctx.Err()
		case <-time.After(lockPoll):
		}
	}
}

// lockPoll is how often a waiting core tries the lock again.
const lockPoll = 200 * time.Millisecond
