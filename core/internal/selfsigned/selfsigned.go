// Package selfsigned is the core's own TLS certificate, for a server that
// clients reach without a reverse proxy (LUMEO_TLS=self-signed). Clients
// pin it at pairing instead of trusting a certificate authority, so it
// names the one address they use and never expires: a renewed certificate
// would be a new one for every device to pair again.
package selfsigned

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	certFile = "cert.pem"
	keyFile  = "key.pem"
)

// Load returns the certificate kept in dir, making one when there is none or
// when the one there does not name host. made says a new one was made: paired
// devices pinned the old one and have to pair again.
func Load(dir, host string) (cert tls.Certificate, made bool, err error) {
	cert, err = tls.LoadX509KeyPair(filepath.Join(dir, certFile), filepath.Join(dir, keyFile))
	if err == nil && cert.Leaf.VerifyHostname(host) == nil {
		return cert, false, nil
	}
	// One that cannot be read is not replaced: devices pinned it, and a new
	// one would turn them all away without saying why.
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return tls.Certificate{}, false, fmt.Errorf("read the core's certificate in %s (remove it to make a new one, then pair devices again): %w", dir, err)
	}
	cert, err = generate(host)
	if err != nil {
		return tls.Certificate{}, false, err
	}
	if err := save(dir, cert); err != nil {
		return tls.Certificate{}, false, err
	}
	return cert, true, nil
}

// CertPath is where the certificate is kept in dir, for a process that
// trusts it: the core's own administration commands.
func CertPath(dir string) string { return filepath.Join(dir, certFile) }

// Fingerprint is the SHA-256 of a certificate, as an owner compares it.
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

func generate(host string) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, err
	}
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		// An hour back, for a client whose clock runs a little behind.
		NotBefore: time.Now().Add(-time.Hour),
		// RFC 5280's date for a certificate with no expiry.
		NotAfter:    time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		// Not a CA, so a device that trusts it trusts nothing it signs.
		BasicConstraintsValid: true,
	}
	if ip := net.ParseIP(host); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, nil
}

// save writes the key, then the certificate, each replacing its file whole.
func save(dir string, cert tls.Certificate) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	key, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
	if err != nil {
		return err
	}
	if err := write(dir, keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})); err != nil {
		return err
	}
	return write(dir, certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}))
}

func write(dir, name string, data []byte) error {
	tmp, err := os.CreateTemp(dir, "."+name+"-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), filepath.Join(dir, name))
}
