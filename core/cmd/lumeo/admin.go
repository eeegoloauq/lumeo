package main

import (
	"bytes"
	"encoding/json"
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
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/token"
)

// Administration talks to the running core: it never opens a second database
// or races the service's data lock. The owner token stays on this machine.
func administer(cfg config.Config, args []string, out io.Writer) error {
	method, path := "", ""
	switch {
	case len(args) == 1 && args[0] == "pair":
		method, path = "POST", "/api/v1/pairings"
	case len(args) == 1 && args[0] == "devices":
		method, path = "GET", "/api/v1/devices"
	case len(args) == 2 && args[0] == "revoke":
		method, path = "DELETE", "/api/v1/devices/"+url.PathEscape(args[1])
	default:
		return fmt.Errorf("usage: lumeo-core [pair | devices | revoke <device-id>]")
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
	request, err := http.NewRequest(method, "http://"+net.JoinHostPort(host, port)+path, bytes.NewBufferString("{}"))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(secret)))
	request.Header.Set("Content-Type", "application/json")
	// A local administrative call must not send its token through HTTP_PROXY
	// or follow a redirect to another machine.
	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("contact running core: %w", err)
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
	}
	return err
}
