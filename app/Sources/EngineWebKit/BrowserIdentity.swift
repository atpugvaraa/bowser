import Foundation

/// What the browser tells websites it is (the User-Agent). Many sites serve stripped-down or "unsupported browser" pages to a bare WebKit view,
/// so the default is Safari (same engine, honest). The others exist for sites that only trust Chrome or Firefox; they are a disguise, the engine stays WebKit
/// (no Chrome-only APIs appear), so a site that detects features rather than the name may still behave differently.
public enum BrowserIdentity: String, CaseIterable, Sendable {
  case safari, chrome, firefox, edge
  public static let defaultsKey = "browserIdentity"

  public var title: String { switch self { case .safari: return "Safari (default)"; case .chrome: return "Chrome"; case .firefox: return "Firefox"; case .edge: return "Edge" } }

  /// The identity in use (UserDefaults, so it survives restarts). Unknown values fall back to Safari.
  public static var current: BrowserIdentity {
    get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(BrowserIdentity.init(rawValue:)) ?? .safari }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
  }

  // Versions follow current stable releases; Chrome/Edge use the reduced-UA form (minor parts 0) like the real browsers.
  static let chromeMajor = 145, firefoxMajor = 145
  /// nil = leave WebKit's own string (which carries "Version/x Safari/605.1.15" from the configuration).
  public var fullUserAgent: String? {
    switch self {
    case .safari: return nil
    case .chrome: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromeMajor).0.0.0 Safari/537.36"
    case .edge: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromeMajor).0.0.0 Safari/537.36 Edg/\(Self.chromeMajor).0.0.0"
    case .firefox: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(Self.firefoxMajor).0) Gecko/20100101 Firefox/\(Self.firefoxMajor).0"
    }
  }
}
