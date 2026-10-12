// swift-tools-version:6.0
import PackageDescription
// Modular core. Dependencies point down only (see docs/architecture/ARCHITECTURE.md).
// Tests are self-checking executables until Xcode (XCTest) is installed.
let package = Package(
  name: "Browser",
  platforms: [.macOS("15.4")],
  products: [.library(name: "BrowserCore", targets: ["BrowserCore"]), .library(name: "Lifecycle", targets: ["Lifecycle"]), .library(name: "Persistence", targets: ["Persistence"]), .library(name: "EngineWebKit", targets: ["EngineWebKit"]), .library(name: "Resources", targets: ["Resources"]), .library(name: "EngineCore", targets: ["EngineCore"]), .library(name: "ContentBlocking", targets: ["ContentBlocking"])],
  targets: [
    .target(name: "BrowserCore"),
    .target(name: "Lifecycle", dependencies: ["BrowserCore"]),
    .target(name: "Persistence", dependencies: ["BrowserCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "EngineWebKit", dependencies: ["BrowserCore", "EngineCore"]),
    .target(name: "Resources", dependencies: ["BrowserCore"]),
    .target(name: "EngineCore", dependencies: ["BrowserCore", "Lifecycle", "Persistence"]),
    .target(name: "ContentBlocking"),
    .executableTarget(name: "EngineStress", dependencies: ["BrowserCore", "Lifecycle", "EngineWebKit", "EngineCore", "Persistence", "ContentBlocking"]),
    .executableTarget(name: "BrowserApp", dependencies: ["BrowserCore", "Lifecycle", "Persistence", "Resources", "EngineCore", "EngineWebKit", "ContentBlocking"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "PolicySim", dependencies: ["BrowserCore", "Lifecycle"]),
    .executableTarget(name: "EngineScale", dependencies: ["BrowserCore", "Lifecycle", "EngineWebKit", "Persistence", "Resources"]),
    .executableTarget(name: "CoreChecks", dependencies: ["BrowserCore", "Lifecycle", "Persistence", "Resources", "EngineCore"]),
  ]
)
