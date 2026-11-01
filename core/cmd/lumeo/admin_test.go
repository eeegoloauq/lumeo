package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/config"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
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
