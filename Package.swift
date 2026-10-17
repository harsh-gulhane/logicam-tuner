// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CamDial",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CamDialKit", targets: ["CamDialKit"]),
        .executable(name: "camdial", targets: ["camdial"]),
        .executable(name: "CamDialApp", targets: ["CamDialApp"]),
    ],
    targets: [
        .target(
            name: "CUSBTransport",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "CamDialKit", dependencies: ["CUSBTransport"]),
        .executableTarget(name: "camdial", dependencies: ["CamDialKit"]),
        .executableTarget(name: "CamDialApp", dependencies: ["CamDialKit"]),
        // Runs without XCTest/swift-testing, which Command Line Tools-only installs may lack.
        .executableTarget(name: "CamDialKitChecks", dependencies: ["CamDialKit"], path: "Tests/CamDialKitChecks"),
    ]
)
