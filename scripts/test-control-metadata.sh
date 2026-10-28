#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
build="$PWD/.build/control-metadata-tests"
mkdir -p "$build/ModuleCache"
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$build/ModuleCache" -parse-as-library \
 Sources/SSHObservatory/ControlAPI.swift Sources/SSHObservatory/ControlAPIModel.swift \
 Sources/SSHObservatory/ControlConsoleAPI.swift Sources/SSHObservatory/ControlConsoleSchema.swift Sources/SSHObservatory/ControlReferralPlan.swift Sources/SSHObservatory/ControlConsoleModel.swift \
 Sources/SSHObservatory/ControlMetadataDraft.swift Sources/SSHObservatory/ControlMetadataAPI.swift Sources/SSHObservatory/ControlMetadataModel.swift \
 Tests/ControlMetadataChecks.swift -o "$build/ControlMetadataChecks"
"$build/ControlMetadataChecks" "${OBSERVATORY_METADATA_WIRE:-$PWD/Tests/Fixtures}"
