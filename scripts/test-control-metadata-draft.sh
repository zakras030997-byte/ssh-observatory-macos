#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
build="$PWD/.build/control-metadata-draft-tests"
mkdir -p "$build/ModuleCache"
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 \
  -module-cache-path "$build/ModuleCache" -parse-as-library \
  Sources/SSHObservatory/ControlMetadataDraft.swift Tests/ControlMetadataDraftChecks.swift \
  -o "$build/ControlMetadataDraftChecks"
"$build/ControlMetadataDraftChecks"
