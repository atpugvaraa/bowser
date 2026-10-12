// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "vt", platforms: [.macOS("14.0")],
  targets: [.executableTarget(name: "vt", path: "Sources/vt", swiftSettings: [.swiftLanguageMode(.v5)])])
