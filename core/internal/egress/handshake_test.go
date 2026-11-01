package egress

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
)

// go.mod turns the post-quantum key exchanges off for every TLS client in
// the binary, the torrent engine's trackers included: a network that drops a
// handshake offering one leaves the addons answering nothing.
func TestNoHandshakeOffersAPostQuantumKeyExchange(t *testing.T) {
	var offered []tls.CurveID
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	server.TLS = &tls.Config{GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
		offered = hello.SupportedCurves
		return nil, nil
	}}
	server.StartTLS()
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(server.Certificate())
	transport := h2Transport()
	transport.TLSClientConfig = &tls.Config{RootCAs: roots}
	defer transport.CloseIdleConnections()

	resp, err := (&http.Client{Transport: transport}).Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if !slices.Contains(offered, tls.X25519) {
		t.Fatalf("offered %v, not X25519", offered)
	}
	for _, curve := range []tls.CurveID{tls.X25519MLKEM768, tls.SecP256r1MLKEM768, tls.SecP384r1MLKEM1024} {
		if slices.Contains(offered, curve) {
			t.Fatalf("offered %v, among them %v", offered, curve)
		}
	}
}
