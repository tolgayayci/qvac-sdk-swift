// swift-tools-version: 5.10
//
// YK-221 benchmark suite.
//
// Three sub-benchmarks, one executable. Pass the bench name as
// the first argument:
//   swift run -c release Benchmark rpc      # pure RTT, no model
//   swift run -c release Benchmark embed    # batched embed/sec
//   swift run -c release Benchmark completion  # TTFT + tok/sec
//
// JS counterparts live in `Benchmarks/js/`; the comparison script
// is `Benchmarks/compare.mjs`. See `docs/perf/baseline.md` for
// methodology.

import PackageDescription

let package = Package(
  name: "Benchmark",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "qvac-sdk-swift", path: "..")
  ],
  targets: [
    .executableTarget(
      name: "Benchmark",
      dependencies: [
        .product(name: "QVACClient", package: "qvac-sdk-swift")
      ],
      path: "Sources/Benchmark"
    )
  ]
)
