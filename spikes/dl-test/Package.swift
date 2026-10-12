// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "dl", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "dl", path: "Sources/dl", swiftSettings: [.swiftLanguageMode(.v5)])])
