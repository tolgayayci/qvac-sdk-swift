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
    )
    // bare-kit-swift — intentionally not listed here in M1.
    // Its native `BareKit` framework is built/downloaded outside SPM,
    // and the consumer (`BareKitIPCTransport`) lands in YK-206. The
    // intended pin (`ef26bbd`) is documented in `docs/dependencies.md`
    // §"Current pins" and will be added to this list at that time.
  ],
  targets: [
    .target(
      name: "QVACClient",
      dependencies: [
        .product(name: "BareRPC", package: "bare-rpc-swift")
      ],
      path: "Sources/QVACClient",
      exclude: [
        // Sidecar metadata for codegen-drift checks; not compiled.
        "Generated/ErrorCodes.json"
      ]
    ),
    .testTarget(
      name: "QVACClientTests",
      dependencies: ["QVACClient"],
      path: "Tests/QVACClientTests"
    ),
  ]
)
