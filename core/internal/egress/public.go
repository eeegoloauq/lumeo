package egress

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"syscall"
	"time"
)

// ErrPrivateAddress is a fetch an addon named refused because it leads into
// this machine or the network it sits on.
var ErrPrivateAddress = errors.New("egress: address is on this machine or its local network")

// Addressed carries the requests for URLs an addon hands the core to fetch on
// its own — images, subtitle files — as opposed to requests to the addon's
// own address, which the user chose and which may well be on their network.
// An addon's answer is a stranger's text, and without this it could have the
// core send GETs to the router or to a service on localhost (the core has no
// authentication), with the addon choosing path and query. The check is made
// on the address actually dialled, after DNS and on every redirect.
var Addressed http.RoundTripper = retry{public{direct: publicTransport(), proxied: h2Transport()}}

// public sends a request direct through a dialler that refuses private
// addresses, or through the user's proxy. Behind a proxy it is the proxy that
// resolves names, so only an address written into the URL can be refused.
type public struct{ direct, proxied http.RoundTripper }

func (p public) RoundTrip(req *http.Request) (*http.Response, error) {
	proxy, err := http.ProxyFromEnvironment(req)
	if err != nil {
		return nil, err
	}
	if proxy == nil {
		return p.direct.RoundTrip(req)
	}
	host := req.URL.Hostname()
	if strings.EqualFold(host, "localhost") {
		return nil, fmt.Errorf("%w: %s", ErrPrivateAddress, host)
	}
	if addr, err := netip.ParseAddr(host); err == nil && refused(addr) {
		return nil, fmt.Errorf("%w: %s", ErrPrivateAddress, host)
	}
	return p.proxied.RoundTrip(req)
}

func publicTransport() *http.Transport {
	t := h2Transport()
	t.Proxy = nil
	t.DialContext = PublicDialContext
	return t
}

// A dial gives up in 5 s so a black-holed address leaves the retry time
// inside the artwork client's 20 s.
var publicDialer = &net.Dialer{
	Timeout:   5 * time.Second,
	KeepAlive: 30 * time.Second,
	Control: func(_, address string, _ syscall.RawConn) error {
		ap, err := netip.ParseAddrPort(address)
		if err != nil {
			return err
		}
		if refused(ap.Addr()) {
			return fmt.Errorf("%w: %s", ErrPrivateAddress, ap.Addr())
		}
		return nil
	},
}

// PublicDialContext dials only public addresses. The torrent engine announces
// to HTTP trackers through it, since tracker URLs come from addons too.
func PublicDialContext(ctx context.Context, network, address string) (net.Conn, error) {
	return publicDialer.DialContext(ctx, network, address)
}

var (
	thisNetwork = netip.MustParsePrefix("0.0.0.0/8")
	sharedNAT   = netip.MustParsePrefix("100.64.0.0/10") // carrier NAT, and Tailscale
)

// refused is swapped by tests whose fake addons listen on loopback.
var refused = private

func private(addr netip.Addr) bool {
	addr = addr.Unmap()
	return addr.IsLoopback() || addr.IsPrivate() || addr.IsUnspecified() ||
		addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() ||
		addr.IsInterfaceLocalMulticast() || addr.IsMulticast() ||
		thisNetwork.Contains(addr) || sharedNAT.Contains(addr)
}

// AllowPrivateAddresses lifts the refusal until the returned function is
// called. Only for tests, which serve fake addons on loopback.
func AllowPrivateAddresses() (restore func()) {
	refused = func(netip.Addr) bool { return false }
	return func() { refused = private }
}
