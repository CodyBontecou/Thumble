// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThumbleMobileInput",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "ThumbleMobileInput", targets: ["MobileInputCore", "MobileInputUIKit"])
  ],
  dependencies: [.package(path: "../../../packages/contracts/generated/swift")],
  targets: [
    .target(
      name: "MobileInputCore", dependencies: [.product(name: "ThumbleContracts", package: "swift")]),
    .target(name: "MobileInputUIKit", dependencies: ["MobileInputCore"]),
    .testTarget(
      name: "MobileInputTests",
      dependencies: ["MobileInputCore", .product(name: "ThumbleContracts", package: "swift")],
      resources: [.copy("Fixtures")]),
  ]
)
