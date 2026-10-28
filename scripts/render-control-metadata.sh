#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
build="$PWD/.build/control-metadata-render"
mkdir -p "$build/ModuleCache"
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$build/ModuleCache" -parse-as-library \
 Sources/SSHObservatory/ControlAPI.swift Sources/SSHObservatory/ControlAPIModel.swift \
 Sources/SSHObservatory/ControlConsoleAPI.swift Sources/SSHObservatory/ControlConsoleSchema.swift Sources/SSHObservatory/ControlReferralPlan.swift Sources/SSHObservatory/ControlConsoleModel.swift \
 Sources/SSHObservatory/ControlMetadataDraft.swift Sources/SSHObservatory/ControlMetadataAPI.swift Sources/SSHObservatory/ControlMetadataModel.swift Sources/SSHObservatory/ControlMetadataView.swift \
 Tests/ControlMetadataRender.swift -o "$build/ControlMetadataRender"
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
"$build/ControlMetadataRender" "${OBSERVATORY_METADATA_WIRE:-$PWD/Tests/Fixtures}" "$@"
