// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "probe", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "probe", path: "Sources/probe", swiftSettings: [.swiftLanguageMode(.v5)])])
