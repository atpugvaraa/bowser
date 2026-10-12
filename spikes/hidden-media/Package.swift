// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "hm", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "hm", path: "Sources/hm", swiftSettings: [.swiftLanguageMode(.v5)])])
