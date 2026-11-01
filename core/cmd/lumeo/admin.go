package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
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

	"github.com/eeegoloauq/lumeo/core/internal/config"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/selfsigned"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/token"
)

// Administration talks to the running core: it never opens a second database
// or races the service's data lock. The owner token stays on this machine.
func administer(cfg config.Config, args []string, out io.Writer) error {
	method, path := "", ""
	switch {
	case (len(args) == 3 || len(args) == 4) && args[0] == "link":
		return link(cfg, args[1:], out)
	case len(args) == 1 && args[0] == "unlink":
		if err := remote.Remove(cfg.DataDir); err != nil {
			return err
		}
		_, err := fmt.Fprintln(out, "Unlinked. Restart the core; revoke the device on the server to remove its access.")
		return err
	case len(args) == 1 && args[0] == "pair":
		method, path = "POST", "/api/v1/pairings"
	case len(args) == 1 && args[0] == "devices":
		method, path = "GET", "/api/v1/devices"
	case len(args) == 2 && args[0] == "revoke":
		method, path = "DELETE", "/api/v1/devices/"+url.PathEscape(args[1])
	case len(args) == 1 && args[0] == "health":
		// A container's health check: a distroless image has no curl. /about
		// is this core's own answer; /healthz on a linked core is the server's.
		method, path = "GET", "/api/v1/about"
	default:
		return fmt.Errorf("usage: lumeo-core [pair | devices | revoke <device-id> | link <https-url> <code> [name] | unlink | health]")
	}
	secret, err := os.ReadFile(filepath.Join(cfg.DataDir, token.FileName))
	if err != nil {
		return fmt.Errorf("read running core's token: %w", err)
	}
	host, port, err := net.SplitHostPort(cfg.Addr)
	if err != nil {
		return err
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	// A local administrative call must not send its token through HTTP_PROXY
	// or follow a redirect to another machine.
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	attempts, err := schemes(cfg)
	if err != nil {
		return err
	}
	var response *http.Response
	for i, attempt := range attempts {
		request, err := http.NewRequest(method, attempt.scheme+"://"+net.JoinHostPort(host, port)+path, bytes.NewBufferString("{}"))
		if err != nil {
			return err
		}
		request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(secret)))
		request.Header.Set("Content-Type", "application/json")
		client.Transport = attempt.transport
		defer attempt.transport.CloseIdleConnections()
		response, err = client.Do(request)
		if err == nil {
			break
		}
		if i == len(attempts)-1 {
			return fmt.Errorf("contact running core: %w", err)
		}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("core answered %s: %s", response.Status, strings.TrimSpace(string(body)))
	}
	switch args[0] {
	case "pair":
		var pairing struct {
			Code      string    `json:"code"`
			ExpiresAt time.Time `json:"expiresAt"`
		}
		if err := json.Unmarshal(body, &pairing); err != nil {
			return err
		}
		_, err = fmt.Fprintf(out, "Pairing code: %s\nExpires: %s\n", pairing.Code, pairing.ExpiresAt.Format(time.RFC3339))
	case "devices":
		var list struct {
			Devices []store.Device `json:"devices"`
		}
		if err := json.Unmarshal(body, &list); err != nil {
			return err
		}
		for _, device := range list.Devices {
			if _, err = fmt.Fprintf(out, "%s\t%s\t%s\n", device.ID, device.CreatedAt.Format(time.RFC3339), device.Name); err != nil {
				return err
			}
		}
	case "revoke":
		_, err = fmt.Fprintln(out, "Device revoked. New requests will be refused; an existing stream may finish.")
	case "health":
		_, err = fmt.Fprintln(out, "ok")
	}
	return err
}

// link pairs this core with a server, as a device of it, and keeps the
// credential in the data directory. It needs no running core: the link is
// read when the core starts.
func link(cfg config.Config, args []string, out io.Writer) error {
	if cfg.Mode == remote.ModeMedia {
		return remote.ErrIsMediaServer
	}
	name := ""
	if len(args) == 3 {
		name = args[2]
	} else if host, err := os.Hostname(); err == nil {
		name = host
	}
	paired, err := remote.Pair(context.Background(), args[0], args[1], name)
	if err != nil {
		return err
	}
	if err := remote.Save(cfg.DataDir, paired); err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "Linked to the media server %s as %q. Restart the core to use it.\n", paired.URL, name)
	return err
}

type attempt struct {
	scheme    string
	transport *http.Transport
}

// schemes is how to reach the running core: over its own certificate when
// it has one, trusting that alone under the name it carries, since the
// address here is loopback and the unit's environment, which says whether
// it serves TLS, is not this command's; then plain HTTP, for a core that
// serves none or no longer does.
func schemes(cfg config.Config) ([]attempt, error) {
	plain := attempt{"http", &http.Transport{Proxy: nil}}
	data, err := os.ReadFile(selfsigned.CertPath(cfg.TLSDir()))
	if errors.Is(err, os.ErrNotExist) {
		return []attempt{plain}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read running core's certificate: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("read running core's certificate: no certificate in it")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("read running core's certificate: %w", err)
	}
	name := ""
	if len(cert.DNSNames) > 0 {
		name = cert.DNSNames[0]
	} else if len(cert.IPAddresses) > 0 {
		name = cert.IPAddresses[0].String()
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	secure := attempt{"https", &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: pool, ServerName: name}}}
	return []attempt{secure, plain}, nil
}
