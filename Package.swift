// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lockgate",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lockgate", targets: ["LockgateApp"]),
        .executable(name: "lockgate-diagnostics", targets: ["LockgateDiagnostics"])
    ],
    targets: [
        .target(name: "LockgateCore"),
        .executableTarget(name: "LockgateApp", dependencies: ["LockgateCore"]),
        .executableTarget(name: "LockgateDiagnostics", dependencies: ["LockgateCore"]),
        .executableTarget(name: "LockgateFilter", dependencies: ["LockgateCore"]),
        .testTarget(name: "LockgateCoreTests", dependencies: ["LockgateCore"])
    ]
)
