// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThumbleWowCaptureMac", platforms: [.macOS(.v14)],
  products: [
    .library(name: "WowCaptureMac", targets: ["WowCaptureMac"]),
    .executable(name: "thumble-wow-capture-macos", targets: ["WowCaptureHelper"]),
  ],
  targets: [
    .target(name: "WowCaptureMac"),
    .executableTarget(name: "WowCaptureHelper", dependencies: ["WowCaptureMac"]),
    .testTarget(
      name: "WowCaptureTests", dependencies: ["WowCaptureMac"], resources: [.copy("Fixtures")]),
  ])
