package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/config"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/selfsigned"
)

// A media server is refused before anything is asked of the other server.
func TestAMediaServerDoesNotLink(t *testing.T) {
	cfg := config.Config{DataDir: t.TempDir(), Mode: remote.ModeMedia}
	err := administer(cfg, []string{"link", "https://127.0.0.1:1", "code"}, io.Discard)
	if !errors.Is(err, remote.ErrIsMediaServer) {
		t.Fatalf("linking a media server: %v", err)
	}
}

func TestAdministratorPairsThroughTheRunningCore(t *testing.T) {
	cfg := testConfig(t, t.TempDir(), true)
	core := startCore(t, cfg)
	core.waitListening(t)
	defer core.stop(t)
	var out bytes.Buffer
	if err := administer(cfg, []string{"pair"}, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(out.String(), "\n")
	code := strings.TrimPrefix(lines[0], "Pairing code: ")
	request, err := http.NewRequest("POST", "http://"+cfg.Addr+"/api/v1/pair", strings.NewReader(`{"code":"`+code+`","name":"Laptop"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	var paired struct {
		Token  string `json:"token"`
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if response.StatusCode != 201 || json.Unmarshal(body, &paired) != nil {
		t.Fatalf("pair: %d %s", response.StatusCode, body)
	}
	out.Reset()
	if err := administer(cfg, []string{"devices"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), paired.Device.ID) || strings.Contains(out.String(), paired.Token) {
		t.Fatal("device list does not identify the device safely")
	}
	if err := administer(cfg, []string{"revoke", paired.Device.ID}, &out); err != nil {
		t.Fatal(err)
	}
	if core.get(t, paired.Token) != 401 {
		t.Fatal("revoked device can still connect")
	}
}

// The container's health check passes while the core answers and fails once
// it has stopped.
func TestHealthFollowsTheRunningCore(t *testing.T) {
	cfg := testConfig(t, t.TempDir(), true)
	core := startCore(t, cfg)
	core.waitListening(t)
	var out bytes.Buffer
	if err := administer(cfg, []string{"health"}, &out); err != nil || out.String() != "ok\n" {
		t.Fatalf("health of a running core: %v %q", err, out.String())
	}
	core.stop(t)
	if err := administer(cfg, []string{"health"}, io.Discard); err == nil {
		t.Fatal("health passed with the core stopped")
	}
}

// With its own certificate the core serves HTTPS only, its administration
// commands reach it over that certificate, and a device pairs by proving the
// code over the certificate it was shown.
func TestACoreWithItsOwnCertificate(t *testing.T) {
	cfg := testConfig(t, t.TempDir(), true)
	cfg.TLS = "self-signed"
	cfg.PublicURL = "https://" + cfg.Addr
	core := startCore(t, cfg)
	defer core.stop(t)
	// The commands run without the unit's environment, as sudo runs them:
	// they find the certificate in the data directory.
	admin := config.Config{Addr: cfg.Addr, DataDir: cfg.DataDir}
	deadline := time.Now().Add(20 * time.Second)
	for administer(admin, []string{"health"}, io.Discard) != nil {
		if time.Now().After(deadline) {
			t.Fatal("core did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Go's answer to plain HTTP on a TLS port is a 400 and nothing else.
	if plain, err := http.Get("http://" + cfg.Addr + "/healthz"); err == nil {
		plain.Body.Close()
		if plain.StatusCode != http.StatusBadRequest {
			t.Fatalf("plain HTTP answered %d beside HTTPS", plain.StatusCode)
		}
	}
	var out bytes.Buffer
	if err := administer(admin, []string{"pair"}, &out); err != nil {
		t.Fatal(err)
	}
	code := strings.TrimPrefix(strings.Split(out.String(), "\n")[0], "Pairing code: ")

	// What a device does: take the certificate as shown, prove the code
	// over it, and trust that certificate alone from then on.
	var shown []byte
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			shown = state.PeerCertificates[0].Raw
			return nil
		},
	}}}
	defer client.CloseIdleConnections()
	if _, err := client.Get("https://" + cfg.Addr + "/healthz"); err != nil {
		t.Fatal(err)
	}
	response, err := client.Post("https://"+cfg.Addr+"/api/v1/pair", "application/json",
		strings.NewReader(`{"proof":"`+remote.DeviceProof(code, shown)+`","name":"Laptop"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var paired struct {
		Token string `json:"token"`
		Proof string `json:"proof"`
	}
	if response.StatusCode != 201 || json.NewDecoder(response.Body).Decode(&paired) != nil {
		t.Fatalf("pair: %d", response.StatusCode)
	}
	if paired.Proof != remote.ServerProof(code, shown) {
		t.Fatal("the core did not prove the code over the certificate it showed")
	}
}

// A certificate left from when the core served TLS does not stop the
// commands reaching it once it serves plain HTTP again.
func TestAdministrationReachesACoreThatNoLongerServesTLS(t *testing.T) {
	cfg := testConfig(t, t.TempDir(), true)
	if _, _, err := selfsigned.Load(cfg.TLSDir(), "127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	core := startCore(t, cfg)
	core.waitListening(t)
	defer core.stop(t)
	if err := administer(cfg, []string{"health"}, io.Discard); err != nil {
		t.Fatal(err)
	}
}
