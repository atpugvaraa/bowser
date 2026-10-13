import AppKit
import Foundation

/// Which colour scheme websites see (`prefers-color-scheme`). Default follows macOS, including automatic light/dark switching at sunset.
/// "Always dark/light" sets the appearance of the web views only, so the browser's own chrome keeps following the system.
public enum PageAppearance: String, CaseIterable, Sendable {
  case system, light, dark
  public static let defaultsKey = "pageAppearance"
  public var title: String { switch self { case .system: return "Follow system (default)"; case .light: return "Always light"; case .dark: return "Always dark" } }
  public static var current: PageAppearance {
    get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(PageAppearance.init(rawValue:)) ?? .system }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
  }
  /// nil = inherit from the window / app (the system setting).
  public var nsAppearance: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}
