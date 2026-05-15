// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "QuickstartTutorial",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(
      url: "https://github.com/tolgayayci/qvac-sdk-swift.git",
      branch: "main"
    )
  ],
  targets: [
    .executableTarget(
      name: "QuickstartTutorial",
      dependencies: [
        .product(name: "QVACClient", package: "qvac-sdk-swift")
      ]
    )
  ]
)
