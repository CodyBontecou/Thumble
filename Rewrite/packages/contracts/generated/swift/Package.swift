// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ThumbleRewriteContracts",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ThumbleContracts", targets: ["ThumbleContracts"])],
  targets: [.target(name: "ThumbleContracts", path: ".", sources: ["GamepadStateV1.swift"])]
)
