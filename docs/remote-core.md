# Remote core

The desktop streams from a standalone core through an HTTPS reverse proxy.
The server downloads while playing; the player reads ahead into its bounded
buffer. A full copy on the client is not required. Downloads, preferences and
watch progress belong to the selected core; switching does not merge libraries.

## Server

Build the core as in [Contributing](../CONTRIBUTING.md), or take
`bundle/bin/lumeo-core` from the Linux release tarball. The server needs only
that binary, its data directory and an artwork cache. Qt and mpv are client
dependencies. There is no transcoding or web administration service.
The Linux archive includes the service, user definition and environment example
under `server/`.

For systemd, install the binary at `/usr/local/bin/lumeo-core`, then install
[the user definition](../packaging/server/lumeo-core.sysusers) as
`/usr/lib/sysusers.d/lumeo-core.conf` and run `systemd-sysusers`. Install
[the unit](../packaging/server/lumeo-core.service) as
`/etc/systemd/system/lumeo-core.service` and copy
[the environment example](../packaging/server/core.env.example) to
`/etc/lumeo/core.env`. Set its public origin before starting:

```ini
LUMEO_ADDR=127.0.0.1:7666
LUMEO_PUBLIC_URL=https://lumeo.example.com
```

The unit creates `/var/lib/lumeo` and `/var/cache/lumeo`, private to its
unprivileged user. Downloads stay under the data directory. An external media
directory needs a unit override granting write access to that directory.
Run `systemctl daemon-reload` and `systemctl enable --now lumeo-core`.
Logs are in `journalctl -u lumeo-core`. Closing a remote client leaves it running.

## Container

Each release publishes `ghcr.io/eeegoloauq/lumeo-core` for amd64 and arm64,
tagged with its version, such as `0.1.80-beta.1`; `beta` follows the latest
beta and `latest` the latest release. Start from
[the compose example](../packaging/container/compose.yaml): set
`LUMEO_PUBLIC_URL` and the version, then `docker compose up -d`.

The image holds the binary and CA certificates, no shell. It runs as user
65532 and writes to two volumes: `/data` (database, downloads, owner token)
and `/cache` (artwork, safe to lose). The example also makes the root
filesystem read-only, drops every capability and forbids gaining privileges.
A bind mount instead of a named volume must belong to 65532. The API listens
on port 7666, published to the host's loopback for the reverse proxy below;
with the proxy on another machine, publish it on the private interface
instead. BitTorrent uses port 42069 over TCP and UDP (`LUMEO_TORRENT_PORT`),
published so peers can connect in. Docker's health check runs
`lumeo-core health`.

The commands under [Devices](#devices) run in the container with its
environment: `docker compose exec core lumeo-core pair`, and the same for
`devices`, `revoke` and `health`. Logs are in `docker compose logs core`. The
owner token for a `curl` on the host is `api-token` in the data volume
(`docker volume inspect` gives its path).

## Nginx Proxy Manager

Create a Proxy Host for `lumeo.example.com`, forwarding HTTP to the core's
listener, with a valid certificate and Force SSL enabled. Preserve the
`Authorization` header and Range requests. No WebSocket support or additional
login page is needed for the native client.

When NPM runs on another VM, bind `LUMEO_ADDR` to the core VM's private interface
instead of loopback. Allow the API port from NPM only; do not forward it from
the public internet. The inter-VM connection must use a trusted private network
or an encrypted tunnel. Public clients always use HTTPS.

In the Proxy Host's Advanced configuration, use:

```nginx
proxy_buffering off;
proxy_cache off;
proxy_read_timeout 120s;
```

The timeout covers silence between upstream reads, not the film's duration.
Buffering is disabled so the proxy does not spool video to disk.
`LUMEO_PUBLIC_URL` is an HTTPS origin without a path, query or credentials. It
sets public artwork addresses; forwarded host/protocol headers are ignored.

## Devices

On the server, run as the service user with the same data directory and listen
address as the unit:

```sh
sudo -u lumeo env LUMEO_DATA=/var/lib/lumeo LUMEO_ADDR=127.0.0.1:7666 \
    /usr/local/bin/lumeo-core pair
```

Replace the listen address when bound to a private interface. The command shows
a random single-use code valid for ten minutes. A new code or a server restart
invalidates the old one. Share it privately: it authorizes one device.

In Settings → General → Connect to server, enter the HTTPS address, device name
and code. Certificate errors and redirects are refused. The server issues a
separate device credential and stores only its SHA-256 hash. The client stores
its credential in `core.json` beside `client.json`, with owner-only permissions;
the pairing code is not saved. On Windows this is the user's AppData directory,
whose account ACL remains the security boundary.

A media server ([below](#media-server)) is not saved there: its credential
goes to the app's own core, which forwards to the server, and General shows
the server as a media server. Restart with the offered button. Playback closes and saves its position to the
old core before switching. A remote connection suppresses startup of the bundled
local core. General also offers returning to the local core and forgetting the
remote connection. One remote can be remembered in this version. `LUMEO_CORE`
remains a development override: connection controls are hidden and saved keys
are never sent to the overridden address.

With the same environment and service user, `lumeo-core devices` lists device IDs
and names. `lumeo-core revoke <device-id>` refuses subsequent requests by that
device, restarts included. An already open stream may finish. Forgetting a
connection only erases its local key; revoke it on the server to remove access.
Previously learned artwork URLs remain usable as unguessable bearer addresses.

History, scores, My list and personal preferences do not merge when switching
cores. To carry them, use Settings → General → Personal data: Export while
connected to one core, Import while connected to the other. An import adds to
what is there, keeps the later of two entries and removes nothing.

Administrative commands read the existing owner token locally and contact the
running core without an HTTP proxy or redirects; they never open a second
database. Paired devices cannot issue codes, list devices or revoke access.
They share one owner's library, history, addons and settings and may control
downloads, so pair only trusted devices. Local client files cannot be opened
through the remote core.

## Media server

With `LUMEO_MODE=media` the server keeps files, not people: each device's
history, scores, My list and preferences stay on a core of its own, linked to
the server, and the server refuses them from devices. A desktop client pairs
as above and follows the mode the server answers with: the credential goes to
its own core, which keeps it, and the client talks only to that core. A core
without a client links with `lumeo-core link` ([core](core.md), Linked to a
server). Forgetting the media server in General unlinks the core; revoke the
device on the server to remove its access.

A device keeps a file on the server by its own keep rules, set in Settings →
Downloads, which on a media server shows them in place of the folder, the
disk limit, the keep policy and the transfer limits, all the server owner's:
a watched file one day, an unwatched one seven days after it was last
started or played. The server applies them while the device is offline too,
and no device keeps a file longer than the owner's maximum, thirty days unless
set with the owner token on the server. The owner can also cap what each
device holds, in bytes; every file a device holds counts in full against it,
and a download over it is refused (no limit unless set):

    curl -X PATCH -H "Authorization: Bearer $(sudo cat /var/lib/lumeo/api-token)" \
         -H 'content-type: application/json' -d '{"deviceMaxKeepDays":14,"deviceDiskLimit":107374182400}' \
         localhost:7666/api/v1/preferences

Changing the mode of a server with data is a migration: export each viewer's
personal data first, and import it on their device. A client connected to the
server directly notices the change on its next answer and hands its
credential to its own core; restart it to use that.

## Storage and operations

The existing [keep policy](decisions/downloads.md) applies: the default retains
watched files for thirty days, with a disk limit. Until watched frees them after
the settling period. Active streams are protected. Unwatched and prefetched
episodes are not automatically evicted by the limit; admission checks refuse
downloads that would exhaust available disk. On a media server a file its
devices hold goes by their keep rules instead, watched or not, once no hold
on it lasts. Torrent upload limits are separate from HTTP delivery.

Check `systemctl is-active lumeo-core` (in a container, that `docker compose ps`
says healthy) and an authenticated `GET /healthz` through
public HTTPS. Verify that an unauthenticated call returns 401. Before considering
deployment complete, play a video, seek to an uncached part, pause and resume,
and advance to the next episode through the actual proxy.

Before upgrading, stop the service, back up its entire data directory including
SQLite sidecar files, and keep the old binary. Start the new version and repeat
health and playback checks. To roll back, stop it, restore the old binary and
its matching data backup, then start and check again. Do not roll back by running
an old binary against the upgraded database. In a container the binary is the
image: upgrade by changing its version in the compose file, and roll back to
the old version with the data volume restored from its backup.
