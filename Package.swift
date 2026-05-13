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
    // bare-rpc-swift — frame layer for the IPC duplex. Pinned to the
    // commit examined in YK-176 (feat: bidirectional streams (#16)).
    // PR #13 (backpressure/cork-uncork) is merged into this commit.
    .package(
      url: "https://github.com/holepunchto/bare-rpc-swift.git",
      revision: "3983622"
    ),
    // bare-kit-swift — Swift wrapper for the in-process Bare worklet on
    // iOS/macOS. Resolved + pinned now so M1 has a stable reference,
    // but NOT linked from QVACClient: the package requires a separate
    // native BareKit framework that is built/downloaded outside SPM,
    // and the BareKitIPCTransport that consumes it lands in M2
    // (YK-206). Promoting this to a real target dependency happens
    // at that point.
    .package(
      url: "https://github.com/holepunchto/bare-kit-swift.git",
      revision: "ef26bbd"
    ),
  ],
  targets: [
    .target(
      name: "QVACClient",
      dependencies: [
        .product(name: "BareRPC", package: "bare-rpc-swift")
      ],
      path: "Sources/QVACClient"
    ),
    .testTarget(
      name: "QVACClientTests",
      dependencies: ["QVACClient"],
      path: "Tests/QVACClientTests"
    ),
  ]
)
