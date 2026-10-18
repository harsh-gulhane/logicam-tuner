// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LogiCamTuner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LogiCamKit", targets: ["LogiCamKit"]),
        .executable(name: "logicam", targets: ["logicam"]),
        .executable(name: "LogiCamTunerApp", targets: ["LogiCamTunerApp"]),
    ],
    targets: [
        .target(
            name: "CUSBTransport",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "LogiCamKit", dependencies: ["CUSBTransport"]),
        .executableTarget(name: "logicam", dependencies: ["LogiCamKit"]),
        .executableTarget(name: "LogiCamTunerApp", dependencies: ["LogiCamKit"]),
        // Runs without XCTest/swift-testing, which Command Line Tools-only installs may lack.
        .executableTarget(name: "LogiCamKitChecks", dependencies: ["LogiCamKit"], path: "Tests/LogiCamKitChecks"),
    ]
)
