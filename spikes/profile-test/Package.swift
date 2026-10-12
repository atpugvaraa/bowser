// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "pt", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "pt", path: "Sources/pt", swiftSettings: [.swiftLanguageMode(.v5)])])
