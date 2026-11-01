package remote

import (
	"os"
	"runtime"
	"testing"
)

// The credential goes with every request, so only over HTTPS, or plain HTTP
// to this machine.
func TestLinkTakesOnlyAnHTTPSOrigin(t *testing.T) {
	for address, ok := range map[string]bool{
		"https://lumeo.example.com":      true,
		"https://lumeo.example.com:8443": true,
		"http://127.0.0.1:7667":          true,
		"http://localhost:7667":          true,
		"http://lumeo.example.com":       false,
		"http://192.168.1.10:7666":       false,
		"https://lumeo.example.com/api":  false,
		"https://user@lumeo.example.com": false,
		"https://lumeo.example.com/?a=1": false,
		"lumeo.example.com":              false,
	} {
		if err := (Link{URL: address, Token: "t"}).Validate(); (err == nil) != ok {
			t.Errorf("%s: err = %v, want ok %v", address, err, ok)
		}
	}
}

func TestLinkIsKeptForThisAccountOnly(t *testing.T) {
	dir := t.TempDir()
	if _, ok, err := Load(dir); ok || err != nil {
		t.Fatalf("no link: ok %v, err %v", ok, err)
	}
	want := Link{URL: "https://lumeo.example.com", Token: "secret"}
	if err := Save(dir, Link{URL: want.URL + "/", Token: want.Token}); err != nil {
		t.Fatal(err)
	}
	got, ok, err := Load(dir)
	if err != nil || !ok || got != want {
		t.Fatalf("loaded %+v, %v, %v", got, ok, err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(dir + "/" + FileName)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("mode %v, %v; want 0600", info.Mode().Perm(), err)
		}
	}
	if err := Remove(dir); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := Load(dir); ok {
		t.Fatal("still linked after Remove")
	}
}
