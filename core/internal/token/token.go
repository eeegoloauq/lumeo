// Package token is the secret a client proves it may use the API with.
//
// It lives in a file only the user can read, in the data directory the core
// has locked, so the processes that can present it are the user's own: the
// set that may control the core anyway. Other accounts on the machine reach
// the loopback port too, and without the token they get nothing from it.
package token

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// FileName is the token's file inside the data directory. The client reads
// it from there.
const FileName = "api-token"

// size is the token's length in bytes before hex encoding.
const size = 32

// Load returns the token kept in dir, creating it on first use. It stays the
// same across restarts: a client that read it once keeps working, and the
// artwork addresses derived from it stay valid for the cache behind them.
func Load(dir string) (string, error) {
	path := filepath.Join(dir, FileName)
	data, err := os.ReadFile(path)
	if err == nil {
		if token := strings.TrimSpace(string(data)); valid(token) {
			return token, nil
		}
		// A file cut short or edited by hand is replaced rather than trusted.
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("read api token: %w", err)
	}
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := hex.EncodeToString(buf)
	if err := write(dir, path, token); err != nil {
		return "", fmt.Errorf("write api token: %w", err)
	}
	return token, nil
}

// write puts the token in place whole: a client reading at the same moment
// finds the old file or the new one, never half of it.
func write(dir, path, token string) error {
	// CreateTemp opens with mode 0600 on every platform that has modes.
	f, err := os.CreateTemp(dir, "."+FileName+"-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(token + "\n"); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

func valid(token string) bool {
	if len(token) != 2*size {
		return false
	}
	_, err := hex.DecodeString(token)
	return err == nil
}
