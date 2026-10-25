#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
configuration="${OBSERVATORY_CONFIGURATION:-Release}"
build="${OBSERVATORY_BUILD_DIR:-$PWD/.build/local-$configuration}"
app="${OBSERVATORY_APP_DIR:-$PWD/dist/SSHObservatory-0.2.app}"
mkdir -p "$build"
case "$configuration" in
  Debug) flags=(-Onone -enable-testing) ;;
  Release) flags=(-O -whole-module-optimization) ;;
  *) printf '%s\n' 'Unknown configuration' >&2; exit 1 ;;
esac
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$build/ModuleCache" "${flags[@]}" \
  -emit-library -emit-module -module-name TelemetryCore Sources/TelemetryCore/*.swift \
  -emit-module-path "$build/TelemetryCore.swiftmodule" -o "$build/libTelemetryCore.dylib" \
  -Xlinker -install_name -Xlinker @rpath/libTelemetryCore.dylib -lsqlite3
if [[ "${OBSERVATORY_CORE_ONLY:-0}" == 1 ]]; then exit 0; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$build/ModuleCache" -parse-as-library "${flags[@]}" \
  -I "$build" -L "$build" -lTelemetryCore Sources/SSHObservatory/*.swift \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/SSHObservatory"
cp "$build/libTelemetryCore.dylib" "$app/Contents/Frameworks/"
cp Sources/SSHObservatory/Resources/collector.py "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SSHObservatory</string>
<key>CFBundleIdentifier</key><string>org.sshobservatory.app</string>
<key>CFBundleName</key><string>SSH Observatory</string>
<key>CFBundleDisplayName</key><string>SSH Observatory</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Frameworks/libTelemetryCore.dylib"
codesign --force --sign - "$app"
printf '%s\n' "Built $app ($configuration; local signature; not notarized)."
