// Package egress is how the core's own HTTP calls — addon manifests,
// catalogues, stream and subtitle lists, subtitle files — leave the machine.
// Peer traffic is the torrent engine's and does not pass through here.
package egress

import (
	"net/http"
	"time"
)

// UserAgent names us to addons: some reject Go's default outright.
const UserAgent = "Lumeo/0.1 (+https://github.com/eeegoloauq/lumeo)"

// Transport is Go's default one with HTTP/2 health checks, and one retry.
// Every request to a host shares one HTTP/2 connection, and a connection the
// far side stops answering (seen with torrentio behind Cloudflare, and on a
// VPN switch) looks alive to TCP. A connection that has read nothing for 5 s
// is pinged, and one that misses the ping for 3 s is closed: a dead idle one
// is gone before anyone uses it, and a request caught on one fails in about
// 8 s, inside the addon client's 15 s. A slow answer is not silence here: the
// far side's HTTP/2 stack acks pings while the addon thinks.
//
// A handshake takes a round trip or two; one that has not finished in 3 s is
// an address that takes TCP and drops TLS (seen on CDN nodes blocked by
// address), and Go's 10 s would leave the retry no time inside the caller's
// timeout.
var Transport http.RoundTripper = retry{h2Transport()}

func h2Transport() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.HTTP2 = &http.HTTP2Config{SendPingTimeout: 5 * time.Second, PingTimeout: 3 * time.Second}
	t.TLSHandshakeTimeout = 3 * time.Second
	return t
}

// retry sends a request again once when the connection under it failed. Go
// resends by itself only what never reached the wire; a request caught on a
// connection that died after sending it gets the error, and the next one
// dials a new connection. Only bodiless GET and HEAD are resent, which is
// every call the core makes; an answer, even a 403, is never retried.
type retry struct{ next http.RoundTripper }

func (r retry) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := r.next.RoundTrip(req)
	if err == nil || req.Context().Err() != nil || (req.Body != nil && req.Body != http.NoBody) ||
		(req.Method != http.MethodGet && req.Method != http.MethodHead) {
		return resp, err
	}
	return r.next.RoundTrip(req)
}

// StatusError is a provider answering with something other than 200, which a
// caller has to tell apart from a provider that answered with nothing.
type StatusError struct {
	Provider string
	Status   string
	// Code is Status as a number, for telling a refusal from an outage.
	Code int
}

func (e *StatusError) Error() string { return e.Provider + " returned " + e.Status }
