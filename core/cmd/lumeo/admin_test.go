package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

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
