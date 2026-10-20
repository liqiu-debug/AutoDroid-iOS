// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AutoDroidCore", platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "AutoDroidCore", targets: ["AutoDroidCore"])],
    targets: [.target(name: "AutoDroidCore", path: "Sources/Core"),
              .testTarget(name: "CoreTests", dependencies: ["AutoDroidCore"], path: "Tests/CoreTests")])
