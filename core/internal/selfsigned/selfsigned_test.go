package selfsigned

import (
	"bytes"
	"crypto/x509"
	"os"
	"path/filepath"
	"testing"
)

func TestTheCertificateIsKeptAndNamesTheHost(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "tls")
	for _, host := range []string{"192.168.1.50", "lumeo.lan"} {
		first, made, err := Load(dir, host)
		if err != nil || !made {
			t.Fatalf("%s: first load made=%v err=%v", host, made, err)
		}
		if err := first.Leaf.VerifyHostname(host); err != nil {
			t.Fatal(err)
		}
		if first.Leaf.IsCA || first.Leaf.NotAfter.Year() != 9999 {
			t.Fatalf("%s: CA=%v expires %v", host, first.Leaf.IsCA, first.Leaf.NotAfter)
		}
		again, made, err := Load(dir, host)
		if err != nil || made || !bytes.Equal(again.Certificate[0], first.Certificate[0]) {
			t.Fatalf("%s: not kept: made=%v err=%v", host, made, err)
		}
	}
	for _, name := range []string{certFile, keyFile} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", name, info.Mode(), err)
		}
	}
}

// Devices pinned the certificate there: one that cannot be read stops the
// core rather than being quietly replaced.
func TestAnUnreadableCertificateIsNotReplaced(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := Load(dir, "lumeo.lan"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, keyFile), []byte("broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Load(dir, "lumeo.lan"); err == nil {
		t.Fatal("a broken key was replaced")
	}
}

// A certificate signs nothing: trusting it trusts no other site.
func TestTheCertificateCannotSign(t *testing.T) {
	cert, _, err := Load(t.TempDir(), "lumeo.lan")
	if err != nil {
		t.Fatal(err)
	}
	if cert.Leaf.KeyUsage&x509.KeyUsageCertSign != 0 || !cert.Leaf.BasicConstraintsValid || cert.Leaf.IsCA {
		t.Fatal("the certificate can sign others")
	}
}
