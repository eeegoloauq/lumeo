package egress

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestPrivateAddresses(t *testing.T) {
	for _, a := range []string{"127.0.0.1", "::1", "10.0.0.1", "172.16.5.4", "192.168.1.1", "169.254.169.254",
		"fe80::1", "fd00::1", "0.0.0.0", "::", "100.100.100.100", "::ffff:192.168.1.1", "224.0.0.1"} {
		if !private(netip.MustParseAddr(a)) {
			t.Errorf("%s taken for public", a)
		}
	}
	for _, a := range []string{"1.1.1.1", "104.16.0.1", "2606:4700::1111"} {
		if private(netip.MustParseAddr(a)) {
			t.Errorf("%s taken for private", a)
		}
	}
}

// An addon naming the core itself, or anything else on loopback, gets an
// error and the service behind it gets no request.
func TestAddressedRefusesThisMachine(t *testing.T) {
	t.Setenv("HTTP_PROXY", "")
	t.Setenv("http_proxy", "")
	hit := false
	local := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hit = true }))
	defer local.Close()
	client := &http.Client{Transport: Addressed}
	if _, err := client.Get(local.URL + "/router/reboot"); !errors.Is(err, ErrPrivateAddress) {
		t.Fatalf("got %v, want ErrPrivateAddress", err)
	}
	if _, err := client.Get("http://localhost:" + local.URL[len("http://127.0.0.1:"):] + "/x"); !errors.Is(err, ErrPrivateAddress) {
		t.Fatalf("localhost: got %v, want ErrPrivateAddress", err)
	}
	if hit {
		t.Fatal("the local service was reached")
	}
}
