# Security and the network

## What the core trusts, and what it does not

An audit on 2026-09-24 went at the core as four adversaries: a hostile addon,
a hostile torrent, a web page in the user's browser, and another account on
the same machine. What came out of it is a set of rules, each against a hole
that was real (every one was reproduced before it was fixed):

- **A path is trusted for nothing.** A path in a request is whatever a
  process holding the API token wrote. A download request cannot
  name a local file (`Manager.OpenLocal`, reached only from
  `POST /api/v1/local`, is the one way in), and a local file is read only
  while it holds a video container, checked on the opened file that is then
  served. The name is not the check: a link called `film.mkv` can point at a
  key. Before this, the stream endpoint served `/etc/passwd` and 0600 files.
- **A browser is not a client.** Mutating routes take JSON only, which needs
  a preflight nobody answers, and cross-site requests are refused outright
  (`http.CrossOriginProtection`); the Host check stops DNS rebinding. Before
  this, one route decoded any body and a web page could start a torrent,
  which then seeded.
- **An addon's answer is a stranger's text.** It is read up to 16 MiB. What it
  names for the core to fetch by itself (artwork, subtitle files, HTTP
  trackers) goes only to public addresses, checked on the address dialled
  (behind a proxy, which resolves names, only on an address in the URL); the
  addon's own address is the user's choice and may be on their network, but
  a redirect to any other address is the addon's and is checked the same way.
  Before this, an addon on the network could redirect the core to any other
  service there (2026-11).
  Images that are not web addresses are dropped, and the stream's content
  type comes from a fixed list of video extensions, never from the system's
  mime database for a file name a torrent chose.
- **What reaches the internet from outside.** The API listens on loopback, so
  nothing on the internet can call it. A web page could send requests but
  never read an answer, so no file ever left the machine that way; the
  realistic exposure was to other processes and accounts on the machine and
  to an addon written against Lumeo in particular.

Every account on the machine reached the API until the token (2026-09), and
read out what the data directory's 0700 kept from it: history, addon URLs
with their keys, any video file the user can read. Now every request carries a token:
the core writes a random secret to a 0600 file in the data directory, and
only processes of the same user can read it, which is exactly the set that
may control the core. It is kept across restarts rather than made per start:
the artwork addresses derive from it and the cache behind them outlives a
restart, and a new one per start protects nothing a same-user process could
not read again. Artwork goes by an unguessable address instead of the
header, because an image on screen sends none (`architecture.md`, The API
token). Server mode needs TLS under bearer credentials:
a bearer token on plain HTTP is readable on the way.

Remote deployment uses per-device keys issued through an owner-created,
single-use pairing code over verified HTTPS ([setup](../remote-core.md)).
The owner token stays on the server for console administration. Device keys
are stored as hashes and can be revoked individually; enrollment management
requires the owner token. A device of a media server cannot open a file by
its path on the server or link a server folder, only the owner can; a full
core's devices open the viewer's files as the owner does. Revocation blocks
new requests, while an already authorized stream can finish. The external
origin is configured explicitly, never inferred from untrusted proxy headers.
On a loopback listener the Host guard also permits that configured public
hostname, so a local reverse proxy can preserve Host without disabling the guard.

A media server's credential belongs to the device's own core, not the client.
The client still pairs, because the pair answer is what says the server's
mode: deciding there leaves no window between asking and pairing in which a
server changing mode strands a device, and the same hand-over serves a full
server used directly that turns media, with the credential already issued and
no new code. Rejected: the core pairing with the code, which needs a second
path in the client for a full server and cannot take over a connection the
client already has; the client running `lumeo-core link`, which puts the code
in the process list; the client writing `server.json`, which bypasses the
API. The core checks a handed credential with the server before keeping it,
the route takes the owner token only, so a device paired with this core
cannot point it elsewhere, and the answer never carries the credential back.

## A core's own certificate is pinned, and the pairing code proves it

A server reached without a reverse proxy (`LUMEO_TLS=self-signed`) serves a
certificate it made, which no authority vouches for. It is one P-256
certificate for the host of `LUMEO_PUBLIC_URL`, not a CA, so a device that
trusts it trusts nothing it signs, and with RFC 5280's no-expiry date, since a
renewed certificate is a new one for every device to pair again. It must name
that host: FFmpeg's GnuTLS verifies the name, IP addresses included, so mpv
on Linux plays nothing from a certificate for another, and pairing refuses
one up front with that reason.

The device never sends the code over a connection it cannot verify. It sends
an HMAC of the code over the SHA-256 of the certificate it was shown, which the
server checks against its own: a certificate put in between yields a proof
the server refuses, and the code, 130 random bits, cannot be recovered from
it. The server answers with an HMAC of its own under another label, which only
a holder of the code makes, before the device pins the certificate, so a
server that never issued the code cannot be pinned. Afterwards the exact
certificate is trusted for that origin: Qt lets a request past only that
certificate (`Pins`), mpv gets it beside the system's certificates as
`tls-ca-file` (a trailer still verifies), and a linked core makes it its one
root.

Rejected: trust on first use, which is what an attacker on the first
connection wants; showing a fingerprint for the owner to compare, which
people skip; TLS channel binding through exported keying material, which Qt
does not expose; a private CA minting a certificate per name, more to get
right for names a server cannot learn from inside a container anyway.

## Confinement is a deployment property, not a library choice

The core parses hostile input from the internet: peer wire, bencode, DHT, uTP,
addon JSON. Go being memory-safe changes what that costs — the realistic
failure is a panic, a hang or resource exhaustion, not a shell — but "less
likely to be code execution" is not "safe to run with the user's permissions".

What we do in-process is bounded by what a process can honestly do to itself:
the data directory and the database are 0700/0600, paths from torrent metadata
are checked against the download directory before we ever report them, request
bodies are capped, and the API binds to localhost unless told otherwise.

What actually contains a compromised parser — unprivileged user, no
capabilities, a read-only root with one writable directory, a syscall filter —
belongs to the unit file and the container image
(`packaging/server/lumeo-core.service`, `packaging/container/`), which run the
core as an unprivileged user writing only to its data and cache directories;
the container's example adds the read-only root and drops every capability.
The container runs under the engine's default seccomp profile; the
unit has no `SystemCallFilter` yet. In-process sandboxing (Landlock, seccomp) is the fallback for when
we ship a desktop binary that no unit file wraps; it is not worth a dependency
and a Linux-only code path before there is something to ship.

## A throttled network: give up fast, ask again, keep the system's DNS

Measured on two filtered networks without a VPN: CDN nodes that take
TCP and never finish TLS, handed out by DNS one address per answer for a
30 s TTL, and plain DNS for TMDB's image CDN rewritten to `127.0.0.1` in
transit.

- **The core gives up in seconds.** A TLS handshake gets 3 s and a public
  dial 5 s, so the one existing retry fits inside the caller's timeout.
  Retrying harder in the core buys nothing: the resolver hands the same dead
  address back until its TTL runs out.
- **The client asks again.** One `Artwork` provider behind every
  picture retries a 5xx or a broken connection after 2, 6 and 20 s, which
  outlasts one TTL, then every minute for as long as an Image shows it, and
  takes a 4xx as final. Giving up after the first three left a poster
  blank for as long as its page stayed made after a longer outage (a laptop
  waking, a VPN coming up). An episode's still with a frame of the file to
  stand in gives up after the three instead, so the frame shows offline.
  The core already joins concurrent fetches and caches on disk; only the
  client knows whether a picture is still on screen.
- **HTTP/2 stays.** The dead node fails before any HTTP is spoken, and the
  HTTP/2 ping is what closes a connection stalled mid-body; HTTP/1.1 would
  leave that to the 20 s timeout.
- **No DoH in the core.** It would bypass the user's own resolver (Pi-hole,
  split DNS, the VPN's), send every host name to a third party, add a parser
  for untrusted answers, and cover the core's fetches only, while the spoof
  breaks every program on that machine. On the measured line it also returned the
  same throttled nodes. A spoofed resolver is fixed where it is
  configured: systemd-resolved with `DNSOverTLS`, or the VPN's DNS setting.
