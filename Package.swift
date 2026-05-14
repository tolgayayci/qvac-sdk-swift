// swift-tools-version: 5.10
import PackageDescription

// YK-206 — BareKit.xcframework is a local binary target. Run
// `scripts/download-barekit.sh` once to populate Vendor/. The
// JavaScriptCore-flavored xcframework is ~20MB; full V8 variant
// (also in prebuilds.zip) is ~353MB but uses Apple's built-in
// JavaScriptCore for parity.

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
  ],
  targets: [
    // YK-206: BareKit binary framework — see scripts/download-barekit.sh.
    // Gitignored at Vendor/; SPM consumers run the script before build.
    .binaryTarget(
      name: "BareKit",
      path: "Vendor/BareKit.xcframework"
    ),
    // YK-206: the Obj-C bridging header that surfaces BareKit's
    // Worklet + BareIPC types to Swift.
    .target(
      name: "BareKitBridge",
      dependencies: ["BareKit"],
      path: "Sources/BareKitBridge",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("BareKit")
      ]
    ),
    // YK-206: the small Swift wrappers (Worklet, IPC) inlined from
    // holepunchto/bare-kit-swift to avoid the SPM-dep + framework-
    // search-path coordination overhead. Apache-2.0 licensed
    // upstream; NOTICE updated accordingly.
    .target(
      name: "BareKitWrapper",
      dependencies: ["BareKitBridge"],
      path: "Sources/BareKitWrapper"
    ),
    .target(
      name: "QVACClient",
      dependencies: [
        .product(name: "BareRPC", package: "bare-rpc-swift"),
        "BareKitWrapper",
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
