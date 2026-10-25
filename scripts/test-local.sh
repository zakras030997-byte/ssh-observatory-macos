#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${OBSERVATORY_SDK:-$(xcrun --show-sdk-path)}"
export OBSERVATORY_BUILD_DIR="${OBSERVATORY_BUILD_DIR:-$PWD/.build/test}"
OBSERVATORY_CONFIGURATION=Debug OBSERVATORY_CORE_ONLY=1 bash scripts/build-local.sh

python3 -B - <<'PY'
from pathlib import Path
import re, os
build = Path(os.environ["OBSERVATORY_BUILD_DIR"])
source = Path('Tests/TelemetryCoreTests/CoreTests.swift').read_text().replace('import XCTest\n', '')
methods = re.findall(r'    func (test\w+)\(\)', source)
calls = '\n'.join('        try run("' + name + '", suite.' + name + ')' for name in methods)
runner = '''
@main struct LocalTestRunner {
    static func main() throws {
        let suite = CoreTests()
        func run(_ name: String, _ body: () throws -> Void) throws {
            let before = assertionFailures
            do { try body() } catch { assertionFailures += 1 }
            print((before == assertionFailures ? "PASS " : "FAIL ") + name)
        }
CALLS
        print("Swift checks: COUNT; failures: \\(assertionFailures)")
        if assertionFailures != 0 { exit(1) }
    }
}
'''.replace('CALLS', calls).replace('COUNT', str(len(methods)))
(build / 'CoreChecks.swift').write_text(source + runner)
PY
xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$OBSERVATORY_BUILD_DIR/ModuleCache" -parse-as-library \
  -I "$OBSERVATORY_BUILD_DIR" -L "$OBSERVATORY_BUILD_DIR" -lTelemetryCore scripts/LocalAssertions.swift "$OBSERVATORY_BUILD_DIR/CoreChecks.swift" \
  -Xlinker -rpath -Xlinker @executable_path -o "$OBSERVATORY_BUILD_DIR/CoreChecks"
"$OBSERVATORY_BUILD_DIR/CoreChecks"
python3 -B -m unittest discover -s Tests/CollectorTests -v

xcrun swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx14.0 -module-cache-path "$OBSERVATORY_BUILD_DIR/ModuleCache" -parse-as-library \
  -I "$OBSERVATORY_BUILD_DIR" -L "$OBSERVATORY_BUILD_DIR" -lTelemetryCore \
  Sources/SSHObservatory/TelemetryModel.swift Tests/AppModelChecks.swift \
  -Xlinker -rpath -Xlinker @executable_path -o "$OBSERVATORY_BUILD_DIR/AppModelChecks"
"$OBSERVATORY_BUILD_DIR/AppModelChecks"
