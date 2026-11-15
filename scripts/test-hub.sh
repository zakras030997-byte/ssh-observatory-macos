#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
export OBSERVATORY_BUILD_DIR="${OBSERVATORY_BUILD_DIR:-$PWD/.build/test}"
OBSERVATORY_CONFIGURATION=Debug OBSERVATORY_CORE_ONLY=1 bash scripts/build-local.sh
python3 -B -c 'import os;from pathlib import Path;Path(os.environ["OBSERVATORY_BUILD_DIR"],"HomeModels.swift").write_text(Path("Sources/SSHObservatory/HomeEgressView.swift").read_text().split("struct HomeEgressView: View")[0])'
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$OBSERVATORY_BUILD_DIR/ModuleCache" -parse-as-library \
 -I "$OBSERVATORY_BUILD_DIR" -L "$OBSERVATORY_BUILD_DIR" -lTelemetryCore \
 Sources/SSHObservatory/{ProtectedRoute,TelemetryModel,ContourService,ObservatoryHub,InteractiveSSH,ProtectedSFTP,HomeEgressNetwork,HomeAccessConfiguration}.swift \
 "$OBSERVATORY_BUILD_DIR/HomeModels.swift" Tests/ObservatoryHubChecks.swift \
 -Xlinker -rpath -Xlinker @executable_path -o "$OBSERVATORY_BUILD_DIR/ObservatoryHubChecks"
"$OBSERVATORY_BUILD_DIR/ObservatoryHubChecks"
