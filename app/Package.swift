// swift-tools-version:6.0
import PackageDescription
// Modular core. Dependencies point down only (see docs/architecture/ARCHITECTURE.md).
// Tests are self-checking executables until Xcode (XCTest) is installed.
let package = Package(
  name: "Browser",
  platforms: [.macOS("15.4")],
  products: [.library(name: "BrowserCore", targets: ["BrowserCore"]), .library(name: "Lifecycle", targets: ["Lifecycle"]), .library(name: "Persistence", targets: ["Persistence"]), .library(name: "EngineWebKit", targets: ["EngineWebKit"]), .library(name: "Resources", targets: ["Resources"])],
  targets: [
    .target(name: "BrowserCore"),
    .target(name: "Lifecycle", dependencies: ["BrowserCore"]),
    .target(name: "Persistence", dependencies: ["BrowserCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "EngineWebKit", dependencies: ["BrowserCore"]),
    .target(name: "Resources", dependencies: ["BrowserCore"]),
    .executableTarget(name: "EngineStress", dependencies: ["BrowserCore", "Lifecycle", "EngineWebKit"]),
    .executableTarget(name: "PolicySim", dependencies: ["BrowserCore", "Lifecycle"]),
    .executableTarget(name: "EngineScale", dependencies: ["BrowserCore", "Lifecycle", "EngineWebKit", "Persistence", "Resources"]),
    .executableTarget(name: "CoreChecks", dependencies: ["BrowserCore", "Lifecycle", "Persistence", "Resources"]),
  ]
)
