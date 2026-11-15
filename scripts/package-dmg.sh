#!/bin/bash
# Package only the public, locally signed bundle and explicit first-run files.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/SSH Observatory.app"
output="$PWD/dist/SSH-Observatory-0.7.0-arm64.dmg"
[[ ! -e "$output" ]] || { echo 'Release image already exists; inspect it first.' >&2; exit 1; }
codesign --verify --deep --strict "$app"
stage="$(mktemp -d "$PWD/dist/.dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/SSH Observatory.app"
ln -s /Applications "$stage/Applications"
cp INSTALL.md "$stage/READ ME FIRST.md"
cp scripts/install-protected-service.command "$stage/Install Protected Service.command"
chmod 755 "$stage/Install Protected Service.command"
hdiutil create -volname 'SSH Observatory 0.7.0' -srcfolder "$stage" -format UDZO "$output"
hdiutil verify "$output"
(cd dist && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
