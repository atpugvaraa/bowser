// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "lh", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "lh", path: "Sources/lh", swiftSettings: [.swiftLanguageMode(.v5)])])
