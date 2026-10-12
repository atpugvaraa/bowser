// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "cb", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "cb", path: "Sources/cb", swiftSettings: [.swiftLanguageMode(.v5)])])
