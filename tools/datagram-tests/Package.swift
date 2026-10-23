// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DatagramProtocol", platforms: [.macOS(.v13)], targets: [.target(name: "DatagramProtocol"), .testTarget(name: "DatagramProtocolTests", dependencies: ["DatagramProtocol"])])
