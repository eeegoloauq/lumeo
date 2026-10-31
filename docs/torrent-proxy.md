# Torrent proxy: planned work

Add a SOCKS5 proxy setting to the core for torrent traffic. This is separate
from remote-core access and addon HTTP proxying. The proxy applies on the
machine running the core; a remote client's network settings cannot route
the server's torrent connections.

## Required behaviour

- Offer TCP and TCP + UDP modes. UDP mode requires a proxy implementing
  SOCKS5 UDP ASSOCIATE; a SOCKS5 listener on port 1080 alone proves nothing.
- When enabled, all torrent peer and discovery traffic must use the proxy.
  Cover TCP peers, uTP, DHT, HTTP/HTTPS/WebSocket and UDP trackers, DNS and
  IPv4/IPv6. Disable unsupported paths, including direct incoming connections
  and WebTorrent/WebRTC or webseeds unless they are explicitly covered.
- Never fall back to direct connections when the proxy or one transport fails.
  Reconnect only through the configured proxy. Invalid configuration must fail
  visibly rather than silently starting a direct client.
- A UDP relay failure should leave working proxied TCP peer connections alone.
  A failed TCP peer connection should leave other connections and UDP alone.
  The TCP control connection for UDP ASSOCIATE is different: closing it ends
  that UDP association under RFC 1928, so TCP and UDP are not fully independent.
- A proxy outage stops affected transfers until recovery. Disabling the setting
  is an explicit user action; a transient failure is not permission to bypass it.
- Keep proxy credentials private. Do not log them or expose them in ordinary
  preferences responses to every device.

The app can guarantee that it connects only to the proxy. It cannot guarantee
that the proxy itself uses a VPN: the proxy host needs its own routing and
firewall policy to prevent direct egress when its VPN fails.

## Implementation questions

The pinned dependencies already include `golang.org/x/net v0.60.0`, whose SOCKS5
dialer covers TCP but not UDP ASSOCIATE. The pinned torrent engine has custom
peer dialer/listener hooks, `TrackerListenPacket` and `NewAnacrolixDhtServer`.
The existing `anacrolix/utp` dependency can wrap a supplied `net.PacketConn`.
These are integration points, not proof that complete proxy support is ready.

First prove a UDP transport adapter and its integration without patching the
torrent engine. Prefer existing dependencies. Decide whether a small adapter
or a maintained additional library is appropriate after that investigation;
zero new dependencies is not yet a promise. Do not replace the engine or
upgrade dependencies speculatively. An upstream report about HTTP CONNECT
tracker handling in v1.61.0 also needs consideration if reusing that path
([issue #1038](https://github.com/anacrolix/torrent/issues/1038)).

The setting needs an endpoint, optional authentication, transport mode and a
clear failure state. Decide how configuration changes replace a live torrent
client while keeping downloads and storage consistent. This work must remain
separate from the first remote-core release.

## Validation before release

Use a local SOCKS5 test server and local peers/trackers. Prove actual transfers
over TCP and uTP, DHT discovery, tracker announcements and proxied DNS. Exercise
IPv4/IPv6, cancellation, deadlines and shutdown. Refuse direct egress in the
test environment so successful playback cannot conceal a bypass.

Independently interrupt UDP forwarding, a TCP peer stream, the UDP association's
control connection and the whole proxy. Check surviving connections, recovery
and absence of direct traffic. Test rejected authentication and a proxy without
UDP support. Finally validate the real proxy's UDP relay reachability and its
VPN failure policy; neither has been checked yet.

Protocol reference: [SOCKS5, RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html).
