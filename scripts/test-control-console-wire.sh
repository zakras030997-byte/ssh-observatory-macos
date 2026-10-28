#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
build="$PWD/.build/control-console-wire-tests"
mkdir -p "$build/ModuleCache"
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 \
 -module-cache-path "$build/ModuleCache" -parse-as-library \
 Sources/SSHObservatory/ControlAPI.swift Sources/SSHObservatory/ControlConsoleAPI.swift \
 Sources/SSHObservatory/ControlConsoleSchema.swift Sources/SSHObservatory/ControlReferralPlan.swift Tests/ControlConsoleWireChecks.swift \
 -o "$build/ControlConsoleWireChecks"
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
"$build/ControlConsoleWireChecks" "${1:-$PWD/Tests/Fixtures/WIRE-FIXTURES.json}"
