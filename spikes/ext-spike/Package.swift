// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "spike", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "spike", path: "Sources/spike", swiftSettings: [.swiftLanguageMode(.v5)])])
