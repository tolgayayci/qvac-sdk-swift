// swift-tools-version: 5.10
//
// QVACChat — minimal SwiftUI chat using QVACClient.
//
// Builds as an SPM executable on macOS 14+. The same SwiftUI
// view+view-model layer compiles for iOS 17+ once
// QVACClient.embedded()'s qvac-worker.bundle ships (YK-207 v2);
// today the example runs on macOS via QVACClient.spawning().
//
// To run:
//   1. From the repo root, stage BareKit + the qvac-worker fixture:
//        ./scripts/download-barekit.sh
//        cd Tests/Fixtures/qvac-worker && npm install
//   2. From this directory:
//        swift run QVACChat
//   3. Type a message + Send.

import PackageDescription

let package = Package(
  name: "QVACChat",
  platforms: [.macOS(.v14)],
  dependencies: [
    // Path dep to the parent QVACClient package — avoids the
    // round-trip of pushing/tagging the SDK before the example
    // can build against it.
    .package(name: "qvac-sdk-swift", path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "QVACChat",
      dependencies: [
        .product(name: "QVACClient", package: "qvac-sdk-swift")
      ],
      path: "Sources/QVACChat"
    )
  ]
)
