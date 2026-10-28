# SSH Observatory for macOS

A native macOS SSH dashboard with an optional VPN administration client. SwiftUI, Swift Charts, system OpenSSH, a session-scoped Python collector and local SQLite, with no third-party runtime dependencies. Administration requires a separately operated compatible HTTPS API. No server backend, credentials or operational data are included.

## 01 · How it works

The app uses an existing SSH alias to start a read-only collector in memory. CPU, memory, swap and one network interface update every three seconds; service states every 15 seconds and disk every 30 seconds. Compact cards show CPU charts, memory/disk use, network rates and connection state. Details include memory charts, load averages and service restart counters.

The collector runs only during its SSH session. Closing the app ends its owned connections. No daemon, cron job, remote file, privileged installation or monitoring port is created. Telemetry does not repair or provision a VPN. Administrative changes use separate, explicit preview-and-confirm API operations.

The main screen uses your configured hosts with Connect All / Stop All controls. A clean install contains no private profiles or automatic host discovery. Saved live monitoring can reconnect; global and per-node pauses are preserved. Host/service status is not proof of working client VPN traffic.

## 02 · Requirements and build

- Apple Silicon Mac, macOS 14 or later.
- A matching Swift 6+ compiler and macOS SDK from Xcode or Command Line Tools.
- Linux hosts with Python 3, procfs and permission to read the selected systemd units.
- Existing SSH key authentication and independently verified host keys.

```sh
bash scripts/build-local.sh
open dist/SSHObservatory-0.2.app
```

The script defaults to an optimized Release build and creates a locally ad-hoc-signed app. It is not notarized. It does not change system security settings. If your compiler and default SDK do not match, select an already-installed compatible SDK with OBSERVATORY_SDK. The script does not download or install one.

```sh
OBSERVATORY_CONFIGURATION=Debug bash scripts/build-local.sh
bash scripts/test-local.sh
```

The test script rebuilds the Debug core, runs the same synchronous CoreTests methods through a small local assertion runner, runs Python unittest checks and validates the connection model using an injected fake transport. No live server is contacted by tests. A standard Package.swift is also included for compatible SwiftPM environments; the executable product is SSHObservatory.

Output and cache directories can be selected with OBSERVATORY_BUILD_DIR and OBSERVATORY_APP_DIR. Build/test output belongs outside tracked source files.

## 03 · Add your own hosts

Use Add Server to enter a display name, an existing SSH alias, optional absolute SSH configuration path, optional expected hostname, optional network interface and exact .service unit names. Saving does not start collection. Connect when ready. Use an account with only the permissions needed for monitoring.

[examples/nodes.example.json](examples/nodes.example.json) and [examples/ssh-config.example](examples/ssh-config.example) contain synthetic placeholders only. Configure your own host and validate its host key independently; never copy a private key into this repository.

Profiles and launch preferences are stored in ~/Library/Application Support/SSH Observatory/. The app does not migrate or discover another application's private profiles. It never needs a token embedded in the source.

## 04 · VPN administration

Management contains requests, clients, owner keys, referrals and items needing attention. Capability-gated operations include previews and confirmation, operation status, duration/traffic changes, pause/resume/revoke, subscription redelivery, aliases/notes and summaries. Server-side support and authorization are required; a visible form is not proof of live acceptance.

Configure your own HTTPS endpoint, trusted server CA and existing client-certificate identity in API settings. Identities stay in macOS Keychain. No endpoint, key, certificate, host inventory or customer list is bundled. The compatibility identifier `anodhas.owner-control.r2` is a wire protocol name, not a credential. The private bot/backend is outside this repository.

Mutations bind durable operation IDs, targets and expiring previews. Unknown outcomes are checked by status rather than blindly replayed. Local operation journals contain sensitive metadata and must remain outside Git. TLS verifies the configured CA, hostname and client identity.

Default builds add no ATS exception. Private-CA deployments may explicitly set one exact endpoint hostname when building:

```sh
OBSERVATORY_CONTROL_ATS_HOST=api.example.com bash scripts/build-local.sh
```

This is scoped to that host. The transport still requires HTTPS, CA/hostname validation and mutual TLS; it does not bypass a certificate error.

Client-only checks use fictional records and injected transports, without live endpoints:

```sh
bash scripts/test-control-api.sh
bash scripts/test-control-api-connection.sh
bash scripts/test-control-console.sh
bash scripts/test-control-console-wire.sh
bash scripts/test-control-metadata.sh
bash scripts/test-control-metadata-draft.sh
bash scripts/test-control-session-lifecycle.sh
```

`Tests/Fixtures` contains frozen synthetic JSON responses. Private backend-dependent TLS fixture runners are excluded. Verify live TLS and administrative behavior in your own controlled deployment.

## 05 · Security and resource limits

- Strict host-key checking; no automatic host-key updates, agent/X11 forwarding, port forwarding, shared control sockets or local SSH commands.
- Direct process arguments and an encoded remote bootstrap. Existing user-selected ProxyCommand/ProxyJump configuration remains trusted local policy.
- Nonblocking SSH reads in 4 KiB chunks, at most 16 KiB per readiness callback. Shared admission budget: 128 KiB and four stdout records per six-second window. Oversized or excessive input stops the offending session with a terminal error.
- One pending sample/notification before UI delivery. A busy UI coalesces samples; the skipped count is visible. Duplicate sequence numbers do not refresh liveness.
- At most four reconnect attempts, five seconds apart; authentication and host-key errors stop retries. Ten valid ingress samples reset the retry budget.
- Up to 120 chart points per host and 24 profiles. Local history uses batched transactions, up to 32 pending/in-flight writes, 200000 rows, 64 MiB of JSON payload and seven days of retention. SQLite file/index/journal size is separate; an existing larger file is not automatically shrunk. Retention can delete old samples.
- EOF/SIGHUP and a POSIX alarm stop the collector after 12 seconds without heartbeat, including blocked userspace output. This is not a guarantee against an uninterruptible kernel wait.

No application can trust measurements from an already compromised host. See [SECURITY.md](SECURITY.md) for boundaries and reporting guidance.

## 06 · Metric semantics and limitations

Network rates use a configured interface or the lowest-metric default IPv4 route, avoiding sums across bridges/veth/tunnels. An interface change or counter reset produces a gap. For IPv6-only systems choose an interface explicitly. Missing sources are unknown, never healthy zeroes. Disk capacity, allocated bytes, user-available space and reserved blocks are distinct.

This is a local prototype, not a monitoring SLA. Physical sleep/wake, actual network faults, independently observed Linux process cleanup, live VPN end-to-end checks, long-duration consumption and portability across macOS releases need deployment-specific validation. Local automated tests do not establish those properties. No binary release or performance guarantee is implied.

## 07 · Development and license

Core transport, protocol and history code lives in Sources/TelemetryCore; native UI, API clients and collector live in Sources/SSHObservatory. Tests use temporary data and injected local processes. Do not add operational profiles, keys, host inventories, generated logs, private paths, screenshots or databases to commits.

Known administration limitations: completed operations can require explicit list/detail refresh; an unsupported client-help pane is informational only; live payment, refund and referral acceptance is deployment-specific. This source snapshot is not a claim of complete production acceptance.

Licensed under the [MIT License](LICENSE). Contributions should preserve read-only remote collection, strict SSH trust and bounded resource use.
