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

Restart with the offered button. Playback closes and saves its position to the
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

Administrative commands read the existing owner token locally and contact the
running core without an HTTP proxy or redirects; they never open a second
database. Paired devices cannot issue codes, list devices or revoke access.
They share one owner's library, history, addons and settings and may control
downloads, so pair only trusted devices. Local client files cannot be opened
through the remote core.

## Storage and operations

The existing [keep policy](decisions/downloads.md) applies: the default retains
watched files for thirty days, with a disk limit. Until watched frees them after
the settling period. Active streams are protected. Unwatched and prefetched
episodes are not automatically evicted by the limit; admission checks refuse
downloads that would exhaust available disk. Torrent upload limits are separate
from HTTP delivery.

Check `systemctl is-active lumeo-core` and an authenticated `GET /healthz` through
public HTTPS. Verify that an unauthenticated call returns 401. Before considering
deployment complete, play a video, seek to an uncached part, pause and resume,
and advance to the next episode through the actual proxy.

Before upgrading, stop the service, back up its entire data directory including
SQLite sidecar files, and keep the old binary. Start the new version and repeat
health and playback checks. To roll back, stop it, restore the old binary and
its matching data backup, then start and check again. Do not roll back by running
an old binary against the upgraded database.
