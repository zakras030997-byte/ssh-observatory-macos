#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
build="$PWD/.build/control-console-render"
core="$PWD/.build/local-Release"
mkdir -p "$build/ModuleCache"
sources=()
for file in Sources/SSHObservatory/*.swift; do
  if [[ "$file" != */ObservatoryApp.swift ]]; then sources+=("$file"); fi
done
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 \
 -module-cache-path "$build/ModuleCache" -parse-as-library \
 -I "$core" -L "$core" -lTelemetryCore -Xlinker -rpath -Xlinker "$core" \
 "${sources[@]}" Tests/ControlConsoleRender.swift -o "$build/ControlConsoleRender"
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
"$build/ControlConsoleRender" "$@"
