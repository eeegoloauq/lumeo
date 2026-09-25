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
  addon's own address is the user's choice and may be on their network.
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
header, because an image widget sends none (`architecture.md`, The API
token). Server mode needs the same token over the network, and TLS under it:
a bearer token on plain HTTP is readable on the way.

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
belongs to the unit file and the container, and lands with the first real
deployment. In-process sandboxing (Landlock, seccomp) is the fallback for when
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
- **The client asks again.** One `ArtworkImage` provider behind every
  picture retries a 5xx or a broken connection after 2, 6 and 20 s, which
  outlasts one TTL, and takes a 4xx as final. The core already joins
  concurrent fetches and caches on disk; only the client knows whether a
  picture is still on screen.
- **HTTP/2 stays.** The dead node fails before any HTTP is spoken, and the
  HTTP/2 ping is what closes a connection stalled mid-body; HTTP/1.1 would
  leave that to the 20 s timeout.
- **No DoH in the core.** It would bypass the user's own resolver (Pi-hole,
  split DNS, the VPN's), send every host name to a third party, add a parser
  for untrusted answers, and cover the core's fetches only, while the spoof
  breaks every program on that machine. On the measured line it also returned the
  same throttled nodes. A spoofed resolver is fixed where it is
  configured: systemd-resolved with `DNSOverTLS`, or the VPN's DNS setting.
