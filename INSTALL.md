# Install SSH Observatory 0.7.0

Apple Silicon (arm64), macOS 14 or newer. Intel is not supported by this build.
The application has a local ad-hoc signature, not an Apple Developer ID signature,
and is not notarized. macOS may block opening it. Do not disable Gatekeeper;
review the source and use macOS Privacy & Security's per-app approval only if you
trust this download. Installation on a second physical Mac is not yet verified.

## First run

1. Install Apple Command Line Tools (`xcode-select --install`) for the system
   Python 3 used by the transport. With Homebrew, install `tor` and `obfs4proxy`
   if bridges are needed. This build expects Apple Silicon Homebrew in
   `/opt/homebrew`. Dependencies are not bundled or installed automatically.
2. Open the DMG and drag **SSH Observatory.app** to **Applications**. For an
   update, close the old window and stop its protected service before replacing it.
3. Open **Install Protected Service.command** from the DMG. It registers only
   this user's SSH Observatory helper; no administrator password is needed.
   An unrelated existing service configuration is refused. Login startup stays off.
4. Open the application. Add your own SSH aliases, pinned host keys and inventory
   using the examples bundled in the application's Resources/examples folder.
   Keep your real files in `~/Library/Application Support/SSH Observatory/`.
   No real nodes, credentials or VPN profiles are included.
5. Connect your own VPN. Node operations require a verified VPN association and
   healthy Tor route; there is no direct fallback. Home LAN is a separate optional
   path configured by your own `home-access.json` and private SSH aliases.

Closing the window leaves the protected service running. Use the application's
service menu to stop it explicitly. No working VPN is switched by the installer.

## MCP clients

Configure a stdio MCP server with command `/usr/bin/python3` and one argument:
`/Applications/SSH Observatory.app/Contents/Resources/mcp/server.py`.
The protected service must be running; the window may be closed. The adapter uses
the same service, not a separate SSH client. Only grant MCP to trusted local clients:
it can execute commands with the authority of your configured SSH accounts.

## Verify download

Download the adjacent `.sha256` file and run `shasum -a 256 -c` with that file.
See the repository README and SECURITY.md for transport limits and source builds.
