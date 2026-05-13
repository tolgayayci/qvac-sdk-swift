// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "QVACClient",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "QVACClient", targets: ["QVACClient"])
  ],
  dependencies: [
    // Added in M1-DEPS (YK-177): bare-rpc-swift, bare-kit-swift
  ],
  targets: [
    .target(
      name: "QVACClient",
      path: "Sources/QVACClient"
    ),
    .testTarget(
      name: "QVACClientTests",
      dependencies: ["QVACClient"],
      path: "Tests/QVACClientTests"
    ),
  ]
)
