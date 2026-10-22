// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThumblePairingQRMac", platforms: [.macOS(.v14)],
  products: [
    .library(name: "PairingQR", targets: ["PairingQR"]),
    .executable(name: "thumble-pairing-qr-macos", targets: ["PairingQRHelper"]),
  ],
  targets: [
    .target(name: "PairingQR"),
    .executableTarget(name: "PairingQRHelper", dependencies: ["PairingQR"]),
    .testTarget(name: "PairingQRTests", dependencies: ["PairingQR"]),
  ])
