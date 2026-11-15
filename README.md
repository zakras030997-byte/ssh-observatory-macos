# SSH Observatory for macOS

A native macOS dashboard and local MCP server for hosts you own or are authorized
to administer. SwiftUI and Charts display CPU, memory, disk, network and systemd
status; system OpenSSH handles pinned SSH authentication. The optional management
client connects to a separately deployed mutual-TLS API.

## Background protected transport — 0.7.0

One per-user background service owns node SSH, interactive sessions, SFTP and
telemetry. Both the window and the stdio MCP adapter use its private Unix socket:

```text
Dashboard ─┐
           ├─ local service ─ active VPN ─ Tor ─ pinned SSH / SFTP ─ registered host
MCP client ┘
```

Closing the window leaves the service and its sessions running. Opening the
window reconnects to that service. A distinct helper bundle identity prevents
macOS from mistaking the background process for the visible application. A lock
prevents a second service from taking ownership. The service menu can start or
stop only this application's service. Login startup is disabled by default.

The service discovers a connected macOS VPN association and binds its outbound
SOCKS transport to that tunnel interface. Its own Tor instance must establish an
authenticated healthy circuit before node operations are accepted. Losing the
verified association or Tor route revokes owned sessions; new operations fail
closed. Existing local Tor Browser obfs4 bridges may be used for recovery if
configured. No bridge addresses or VPN profiles are bundled.

**Limits:** a connected VPN association and tunnel-bound socket are not proof
that every provider's internal split rules encrypt every flow. Other SSH clients
are outside this service's enforcement. Disconnecting a local client does not
guarantee termination of an arbitrary remote process. A local user with access
to the service has its registered SSH account authority; MCP annotations are not
an approval system.

## Build and local setup

Requirements: macOS 14+, Apple Silicon, Swift command-line tools with a compatible
SDK, Python 3.9+, system OpenSSH, and local `tor` (plus `obfs4proxy` for configured
obfs4 bridges). The supplied runtime uses the usual Apple Silicon Homebrew paths.
Dependencies are not installed automatically. The package is locally signed;
Developer ID signing, notarization and another physical Mac are not verified.

```sh
bash scripts/build-local.sh
```

The output is `dist/SSH Observatory.app`. Copy it to `/Applications`, then register
the user-owned helper:

```sh
python3 scripts/install-service.py --app '/Applications/SSH Observatory.app'
```

The installer validates the bundle and refuses an unrelated or different existing
job configuration. It registers no root daemon and does not change the active VPN,
network routes, SSH configuration, host pins or remote services. For a later app
update, close its window and stop the service before replacing the bundle.

The service uses `~/Library/Application Support/SSH Observatory/`. Add your own
node inventory there using `examples/nodes.example.json`, with existing aliases
from your private SSH configuration. The example hostnames and documentation IPs
are fictional. Nothing connects merely because an example file is present in this
repository. Use the dashboard's connection controls to enable collection.

For private-CA control API deployments, an optional exact-host ATS exception can
be provided during the build via `OBSERVATORY_CONTROL_ATS_HOST`. HTTPS, the
configured CA, hostname and client identity are still validated. No production
endpoint, server backend or client credential is included.

## MCP

Configure your MCP client to run Python with the absolute path to `mcp/server.py`.
The adapter connects to the service's private `hub.sock`; the window may be closed.
The service must already be running. The adapter never opens a separate SSH path.

Tools include `observatory_status`, `observatory_nodes`,
`observatory_telemetry`, `observatory_connect`, `observatory_inspect`,
`observatory_ssh_exec`, `observatory_ssh_open/read/write/close`,
`observatory_sftp_transfer` and the four `observatory_home_*` tools.

SSH commands may modify registered hosts; the caller must be authorized for their
specific effects. Interactive open returns `connecting`; wait for `ready` before
writing. Terminal data uses base64, writes can be partial, and reads are bounded.
SFTP upload requires explicit overwrite permission; download does not overwrite a
local file. Unknown outcomes must be inspected before replaying a mutation.

`observatory_status` includes service identity and timestamped protected-route
evidence. Missing or stale evidence must not be reported as a working route.
Telemetry is resource evidence, not proof of client VPN traffic.

## Optional Home LAN access

Home remains a distinct explicitly configured LAN path. No home IP, username,
private-key filename, reserve host or expected hostname is built into the public
source. Copy `examples/home-access.example.json` to the local data directory as
`home-access.json`, adapt it to your own authorized hosts, and define both SSH
aliases privately. Home functions refuse connection if this configuration is
absent or invalid. The Home control API requires a compatible separately deployed
loopback service; its server implementation is not part of this repository.

## Validation

```sh
bash scripts/test-local.sh
(cd transport && python3 -B -m unittest discover -q)
python3 -B -m unittest discover -s mcp/tests -q
bash scripts/test-hub.sh
```

The tests use fictional data and isolated sockets/processes. Socket tests require
permission to create local Unix sockets. They cover bounded input, identity and
host-key constraints, cancellation, reconnect, collector lease expiry, history,
client/service delegation, missing-route denial and IPC ownership. No production
inventory, live acceptance logs, screenshots, private configurations or compiled
application packages are included.

## License

MIT. See [LICENSE](LICENSE) and [SECURITY.md](SECURITY.md).
