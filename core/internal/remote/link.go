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
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

// FileName is the links in the data directory: each server's address and this
// core's device credential there, so owner-only, as the api token is.
const FileName = "server.json"

type Link struct {
	URL   string `json:"url"`
	Token string `json:"token"`
	// Certificate is the PEM of the server's own certificate, pinned at
	// pairing, when no authority vouches for the one it serves; empty
	// trusts the system's authorities, as behind a reverse proxy.
	Certificate string `json:"certificate,omitempty"`
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
	if l.Certificate != "" {
		if _, err := l.pinned(); err != nil {
			return err
		}
	}
	return nil
}

// pinned is the link's certificate as the one root a connection trusts, nil
// for a link that trusts the system's authorities.
func (l Link) pinned() (*x509.CertPool, error) {
	if l.Certificate == "" {
		return nil, nil
	}
	block, _ := pem.Decode([]byte(l.Certificate))
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("server link's certificate is not a PEM certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("server link's certificate: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return pool, nil
}

func loopback(host string) bool {
	ip := net.ParseIP(host)
	return host == "localhost" || ip != nil && ip.IsLoopback()
}

// saved is the file: every media server this core holds a device credential
// for, in the order they were first linked, and the one it forwards to, none
// when Use is empty. Switching between them needs no new pairing code.
type saved struct {
	Use   string `json:"use,omitempty"`
	Links []Link `json:"links"`
}

// The API reads the file, changes it and writes it back; one change at a time.
var savedMu sync.Mutex

// ErrNotSaved is a server this core holds no link to.
var ErrNotSaved = errors.New("no saved link to that server")

func read(dataDir string) (saved, error) {
	data, err := os.ReadFile(filepath.Join(dataDir, FileName))
	if errors.Is(err, os.ErrNotExist) {
		return saved{}, nil
	}
	if err != nil {
		return saved{}, err
	}
	var s saved
	if err := json.Unmarshal(data, &s); err != nil {
		return saved{}, fmt.Errorf("read %s: %w", FileName, err)
	}
	// A core from before several links kept the one it used as the file.
	if s.Links == nil {
		var one Link
		if err := json.Unmarshal(data, &one); err == nil && one.URL != "" {
			s = saved{Use: one.URL, Links: []Link{one}}
		}
	}
	s.Use = strings.TrimRight(s.Use, "/")
	for i := range s.Links {
		s.Links[i].URL = strings.TrimRight(s.Links[i].URL, "/")
		if err := s.Links[i].Validate(); err != nil {
			return saved{}, fmt.Errorf("%s: %w", FileName, err)
		}
	}
	if s.Use != "" && s.find(s.Use) < 0 {
		return saved{}, fmt.Errorf("%s uses %s, which it holds no link to", FileName, s.Use)
	}
	return s, nil
}

func (s saved) find(url string) int {
	return slices.IndexFunc(s.Links, func(l Link) bool { return l.URL == url })
}

// write keeps the file readable by this account only, and removes it once it
// holds no link.
func write(dataDir string, s saved) error {
	path := filepath.Join(dataDir, FileName)
	if len(s.Links) == 0 {
		err := os.Remove(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
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
	return os.Rename(tmp.Name(), path)
}

func change(dataDir string, edit func(*saved) error) error {
	savedMu.Lock()
	defer savedMu.Unlock()
	s, err := read(dataDir)
	if err != nil {
		return err
	}
	if err := edit(&s); err != nil {
		return err
	}
	return write(dataDir, s)
}

// Load reads the link this core forwards to; ok is false when it uses none.
func Load(dataDir string) (link Link, ok bool, err error) {
	s, err := read(dataDir)
	if err != nil || s.Use == "" {
		return Link{}, false, err
	}
	return s.Links[s.find(s.Use)], true, nil
}

// Saved lists the servers this core holds a link to, and the one it uses,
// empty for none.
func Saved(dataDir string) (urls []string, use string, err error) {
	s, err := read(dataDir)
	if err != nil {
		return nil, "", err
	}
	for _, l := range s.Links {
		urls = append(urls, l.URL)
	}
	return urls, s.Use, nil
}

// Save keeps link, in place of an earlier one to the same server, and uses it.
func Save(dataDir string, link Link) error {
	link.URL = strings.TrimRight(link.URL, "/")
	if err := link.Validate(); err != nil {
		return err
	}
	return change(dataDir, func(s *saved) error {
		if i := s.find(link.URL); i >= 0 {
			s.Links[i] = link
		} else {
			s.Links = append(s.Links, link)
		}
		s.Use = link.URL
		return nil
	})
}

// Use makes the saved link to url the one forwarded to; empty uses none and
// keeps every link.
func Use(dataDir, url string) error {
	url = strings.TrimRight(url, "/")
	return change(dataDir, func(s *saved) error {
		if url != "" && s.find(url) < 0 {
			return ErrNotSaved
		}
		s.Use = url
		return nil
	})
}

// Forget drops the link to url, and uses none if it was the one in use. The
// server keeps the device until it is revoked there.
func Forget(dataDir, url string) error {
	url = strings.TrimRight(url, "/")
	return change(dataDir, func(s *saved) error {
		if i := s.find(url); i >= 0 {
			s.Links = slices.Delete(s.Links, i, i+1)
		}
		if s.Use == url {
			s.Use = ""
		}
		return nil
	})
}

// ErrIsMediaServer refuses a link on a core that is a media server itself:
// devices forward to it, and its files would be another server's.
var ErrIsMediaServer = errors.New("this core is a media server; only a device's core links to one")

// Verify asks the server, with the link's credential, whether it takes it and
// is a media server: a credential handed over by a client paired with the
// server is checked with it before it is kept.
func Verify(ctx context.Context, link Link) error {
	link.URL = strings.TrimRight(link.URL, "/")
	if err := link.Validate(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	server := New(link, slog.New(slog.DiscardHandler))
	defer server.client.CloseIdleConnections()
	return server.Do(ctx, http.MethodGet, "/healthz", nil, nil, nil)
}

// Pair trades a pairing code the server's owner issued for a device
// credential of this core's own. A server whose certificate no authority
// vouches for is paired by proving the code over the certificate it shows,
// which the link then pins (proof.go).
func Pair(ctx context.Context, address, code, name string) (Link, error) {
	link := Link{URL: strings.TrimRight(address, "/"), Token: "-"}
	if err := link.Validate(); err != nil {
		return Link{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	shown, trusted, err := showCertificate(ctx, link.URL)
	if err != nil {
		return Link{}, err
	}
	body := map[string]string{"code": code, "name": name}
	if shown != nil && !trusted {
		link.Certificate = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: shown.Raw}))
		body = map[string]string{"proof": DeviceProof(code, shown.Raw), "name": name}
	}
	data, err := json.Marshal(body)
	if err != nil {
		return Link{}, err
	}
	// From here on only the certificate just seen, or an authority's.
	transport, err := newTransport(link)
	if err != nil {
		return Link{}, err
	}
	client := &http.Client{Transport: transport, CheckRedirect: refuseRedirect}
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
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, link.URL+"/api/v1/pair", bytes.NewReader(data))
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
		Proof string `json:"proof"`
	}
	if err := json.Unmarshal(answer, &paired); err != nil || paired.Token == "" {
		return Link{}, errors.New("server answered without a credential")
	}
	// Only a holder of the code proves it: anything else is not the server
	// the owner issued it on, and its certificate is not kept.
	if link.Certificate != "" && !ProofHolds(ServerProof(code, shown.Raw), paired.Proof) {
		return Link{}, errors.New("the server did not prove it issued the code; nothing was linked")
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

// showCertificate asks address for nothing but its health, with no
// credential, and returns the certificate it shows and whether the system's
// authorities vouch for it under the address's name. Plain HTTP on loopback
// has none.
func showCertificate(ctx context.Context, address string) (*x509.Certificate, bool, error) {
	u, err := url.Parse(address)
	if err != nil {
		return nil, false, err
	}
	if u.Scheme != "https" {
		return nil, false, nil
	}
	transport, _ := newTransport(Link{})
	// The player checks the name too, so a certificate for another one would
	// pair and then play nothing: it ends the handshake, before anything is
	// sent. Whether an authority vouches for it is checked after, by hand:
	// a certificate none does is what this asks for.
	wrongName := fmt.Errorf("the server's certificate is not for %s; use the address in its LUMEO_PUBLIC_URL", u.Hostname())
	transport.TLSClientConfig = &tls.Config{
		InsecureSkipVerify: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || state.PeerCertificates[0].VerifyHostname(u.Hostname()) != nil {
				return wrongName
			}
			return nil
		},
	}
	client := &http.Client{Transport: transport, CheckRedirect: refuseRedirect}
	defer client.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address+"/healthz", nil)
	if err != nil {
		return nil, false, err
	}
	resp, err := client.Do(req)
	if errors.Is(err, wrongName) {
		return nil, false, wrongName
	}
	if err != nil {
		return nil, false, fmt.Errorf("contact server: %w", err)
	}
	resp.Body.Close()
	chain := resp.TLS.PeerCertificates
	leaf := chain[0]
	intermediates := x509.NewCertPool()
	for _, c := range chain[1:] {
		intermediates.AddCert(c)
	}
	_, err = leaf.Verify(x509.VerifyOptions{DNSName: u.Hostname(), Intermediates: intermediates})
	return leaf, err == nil, nil
}
