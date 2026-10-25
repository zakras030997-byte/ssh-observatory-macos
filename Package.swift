// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHObservatory",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SSHObservatory", targets: ["SSHObservatory"])],
    targets: [
        .target(name: "TelemetryCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "SSHObservatory", dependencies: ["TelemetryCore"], resources: [.copy("Resources/collector.py")]),
        .testTarget(name: "TelemetryCoreTests", dependencies: ["TelemetryCore"])
    ],
    swiftLanguageModes: [.v5]
)
