# SSH Observatory for macOS

A small native macOS dashboard for Linux host resources and selected systemd services. SwiftUI, Swift Charts, system OpenSSH, a session-scoped Python collector, and local SQLite. No cloud backend or third-party runtime dependencies.

## 01 · How it works

The app uses an existing SSH alias to start a read-only collector in memory. CPU, memory, swap and one network interface update every three seconds; service states every 15 seconds and disk every 30 seconds. Compact cards show CPU charts, memory/disk use, network rates and connection state. Details include memory charts, load averages and service restart counters.

The collector runs only during its SSH session. Closing the app ends its owned connections. No daemon, cron job, remote file, privileged installation or monitoring port is created. No VPN repair or account provisioning is performed.

The first launch shows clearly labelled synthetic demo data. Add your own profiles to enable live collection. A saved live mode can reconnect on subsequent launches; global and per-node pauses are preserved. Host/service status is not proof of working client VPN traffic.

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

Use the app's live-mode form to enter a display name, an existing SSH alias, optional absolute SSH configuration path, optional expected hostname, optional network interface and exact .service unit names. Saving does not start collection. Connect when ready. Use an account with only the permissions needed for monitoring.

[examples/nodes.example.json](examples/nodes.example.json) and [examples/ssh-config.example](examples/ssh-config.example) contain synthetic placeholders only. Configure your own host and validate its host key independently; never copy a private key into this repository.

Profiles and launch preferences are stored in ~/Library/Application Support/SSH Observatory/. The app does not migrate or discover another application's private profiles. It never needs a token embedded in the source.

## 04 · Security and resource limits

- Strict host-key checking; no automatic host-key updates, agent/X11 forwarding, port forwarding, shared control sockets or local SSH commands.
- Direct process arguments and an encoded remote bootstrap. Existing user-selected ProxyCommand/ProxyJump configuration remains trusted local policy.
- Nonblocking SSH reads in 4 KiB chunks, at most 16 KiB per readiness callback. Shared admission budget: 128 KiB and four stdout records per six-second window. Oversized or excessive input stops the offending session with a terminal error.
- One pending sample/notification before UI delivery. A busy UI coalesces samples; the skipped count is visible. Duplicate sequence numbers do not refresh liveness.
- At most four reconnect attempts, five seconds apart; authentication and host-key errors stop retries. Ten valid ingress samples reset the retry budget.
- Up to 120 chart points per host and 24 profiles. Local history uses batched transactions, up to 32 pending/in-flight writes, 200000 rows, 64 MiB of JSON payload and seven days of retention. SQLite file/index/journal size is separate; an existing larger file is not automatically shrunk. Retention can delete old samples.
- EOF/SIGHUP and a POSIX alarm stop the collector after 12 seconds without heartbeat, including blocked userspace output. This is not a guarantee against an uninterruptible kernel wait.

No application can trust measurements from an already compromised host. See [SECURITY.md](SECURITY.md) for boundaries and reporting guidance.

## 05 · Metric semantics and limitations

Network rates use a configured interface or the lowest-metric default IPv4 route, avoiding sums across bridges/veth/tunnels. An interface change or counter reset produces a gap. For IPv6-only systems choose an interface explicitly. Missing sources are unknown, never healthy zeroes. Disk capacity, allocated bytes, user-available space and reserved blocks are distinct.

This is a local prototype, not a monitoring SLA. Physical sleep/wake, actual network faults, independently observed Linux process cleanup, live VPN end-to-end checks, long-duration consumption and portability across macOS releases need deployment-specific validation. Local automated tests do not establish those properties. No binary release or performance guarantee is implied.

## 06 · Development and license

Core transport, protocol and history code lives in Sources/TelemetryCore; native UI and collector in Sources/SSHObservatory. Tests use temporary data and injected local processes. Do not add operational profiles, keys, host inventories, generated logs, private paths, screenshots or databases to commits.

Licensed under the [MIT License](LICENSE). Contributions should preserve read-only remote collection, strict SSH trust and bounded resource use.
