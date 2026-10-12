// swift-tools-version:6.0
import PackageDescription
// Modular core. Dependencies point down only (see docs/architecture/ARCHITECTURE.md).
// Tests are self-checking executables until Xcode (XCTest) is installed.
let package = Package(
  name: "Browser",
  platforms: [.macOS("15.4")],
  products: [.library(name: "BrowserCore", targets: ["BrowserCore"]), .library(name: "Lifecycle", targets: ["Lifecycle"])],
  targets: [
    .target(name: "BrowserCore"),
    .target(name: "Lifecycle", dependencies: ["BrowserCore"]),
    .executableTarget(name: "CoreChecks", dependencies: ["BrowserCore", "Lifecycle"]),
  ]
)
