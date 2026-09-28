// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iphone-use",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iphone-use", targets: ["iphone-use"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        // C bindings for MobileDevice.framework. Opened with dlopen, never linked.
        .target(name: "CMobileDevice"),
        // Bridge to DTXConnectionServices.framework. Also dlopen'd, not linked.
        .target(name: "CDTXBridge"),
        .executableTarget(
            name: "iphone-use",
            dependencies: [
                "CMobileDevice",
                "CDTXBridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
