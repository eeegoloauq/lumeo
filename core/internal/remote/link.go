// Package remote is a core's link to the core on a server it forwards to:
// what the server owns (addons, metadata, sources, downloads, streams,
// storage, the subtitles of a download) is asked of it, and the viewer's own
// data stays here. The client talks only to this core, so it stays the same
// whether or not there is a server behind it.
package remote

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// FileName is the link in the data directory: the server's address and this
// core's device credential, so owner-only, as the api token is.
const FileName = "server.json"

type Link struct {
	URL   string `json:"url"`
	Token string `json:"token"`
}

// Validate refuses an address that is not an HTTPS origin, or plain HTTP on
// loopback: the credential goes with every request.
func (l Link) Validate() error {
	u, err := url.Parse(l.URL)
	if err != nil || u.Host == "" || u.User != nil || strings.Trim(u.Path, "/") != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return fmt.Errorf("server address must be an origin, such as https://lumeo.example.com")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && loopback(u.Hostname())) {
		return fmt.Errorf("server address must use HTTPS")
	}
	if l.Token == "" {
		return errors.New("server link has no credential")
	}
	return nil
}

func loopback(host string) bool {
	ip := net.ParseIP(host)
	return host == "localhost" || ip != nil && ip.IsLoopback()
}

// Load reads the link; ok is false when this core has none.
func Load(dataDir string) (link Link, ok bool, err error) {
	data, err := os.ReadFile(filepath.Join(dataDir, FileName))
	if errors.Is(err, os.ErrNotExist) {
		return Link{}, false, nil
	}
	if err != nil {
		return Link{}, false, err
	}
	if err := json.Unmarshal(data, &link); err != nil {
		return Link{}, false, fmt.Errorf("read %s: %w", FileName, err)
	}
	link.URL = strings.TrimRight(link.URL, "/")
	if err := link.Validate(); err != nil {
		return Link{}, false, fmt.Errorf("%s: %w", FileName, err)
	}
	return link, true, nil
}

// Save writes the link, readable by this account only.
func Save(dataDir string, link Link) error {
	link.URL = strings.TrimRight(link.URL, "/")
	if err := link.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(link, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dataDir, FileName+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(dataDir, FileName))
}

// Remove forgets the link. The server keeps the device until it is revoked
// there.
func Remove(dataDir string) error {
	err := os.Remove(filepath.Join(dataDir, FileName))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Pair trades a pairing code the server's owner issued for a device
// credential of this core's own.
func Pair(ctx context.Context, address, code, name string) (Link, error) {
	link := Link{URL: strings.TrimRight(address, "/"), Token: "-"}
	if err := link.Validate(); err != nil {
		return Link{}, err
	}
	body, err := json.Marshal(map[string]string{"code": code, "name": name})
	if err != nil {
		return Link{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	client := &http.Client{Transport: newTransport(), CheckRedirect: refuseRedirect}
	defer client.CloseIdleConnections()
	// Every answer says the server's mode, a refusal of no credential too:
	// asked first, a full server is turned down before it pairs a device
	// its owner would have to revoke.
	probe, err := http.NewRequestWithContext(ctx, http.MethodGet, link.URL+"/healthz", nil)
	if err != nil {
		return Link{}, err
	}
	resp, err := client.Do(probe)
	if err != nil {
		return Link{}, fmt.Errorf("contact server: %w", err)
	}
	resp.Body.Close()
	if err := checkMode(resp); err != nil {
		return Link{}, err
	}
	if resp.Header.Get(ModeHeader) == "" {
		return Link{}, fmt.Errorf("contact server: it answered %s", resp.Status)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, link.URL+"/api/v1/pair", bytes.NewReader(body))
	if err != nil {
		return Link{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err = client.Do(req)
	if err != nil {
		return Link{}, fmt.Errorf("contact server: %w", err)
	}
	defer resp.Body.Close()
	answer, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return Link{}, err
	}
	if resp.StatusCode != http.StatusCreated {
		return Link{}, fmt.Errorf("server answered %s: %s", resp.Status, strings.TrimSpace(string(answer)))
	}
	var paired struct {
		Token string `json:"token"`
		Mode  string `json:"mode"`
	}
	if err := json.Unmarshal(answer, &paired); err != nil || paired.Token == "" {
		return Link{}, errors.New("server answered without a credential")
	}
	// Its mode changed since it was asked. The device is paired by now, and
	// its owner revokes it there.
	if paired.Mode != ModeMedia {
		return Link{}, fmt.Errorf("%w: it became %s while pairing; set LUMEO_MODE=media on it and pair again",
			ErrNotMedia, cmp.Or(paired.Mode, "full"))
	}
	link.Token = paired.Token
	return link, nil
}
