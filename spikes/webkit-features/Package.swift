// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "wf", platforms: [.macOS("15.4")],
  targets: [.executableTarget(name: "wf", path: "Sources/wf", swiftSettings: [.swiftLanguageMode(.v5)]), .executableTarget(name: "wf2", path: "Sources/wf2", swiftSettings: [.swiftLanguageMode(.v5)])])
