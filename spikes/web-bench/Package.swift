// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "wb", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "wb", path: "Sources/wb", swiftSettings: [.swiftLanguageMode(.v5)])])
