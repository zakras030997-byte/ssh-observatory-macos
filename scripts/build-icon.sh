#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_icon="Assets/AppIcon.png"
output_icon="Sources/SSHObservatory/Resources/AppIcon.icns"
temporary_icon=$(mktemp -d "${TMPDIR:-/tmp}/ssh-observatory-icon.XXXXXX")
trap 'rm -rf "$temporary_icon"' EXIT
iconset="$temporary_icon/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output_icon"
printf '%s\n' "Built $output_icon"
