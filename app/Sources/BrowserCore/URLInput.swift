import Foundation

/// Turns what the user typed into a URL to load — or nil if it must not be loaded. Pure, no WebKit.
/// Safety: typed input NEVER becomes a `javascript:`, `data:`, `file:` or other script/local-file navigation (spec C2).
public enum URLInput {
  public static let defaultSearch = "https://duckduckgo.com/?q=%s"

  public static func resolve(_ raw: String, searchTemplate: String = defaultSearch) -> URL? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.utf8.count <= 8192, !s.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } ?? false }) else { return nil }

    // Explicit scheme? Only http(s) (and the blank page) may be typed.
    if let colon = s.firstIndex(of: ":"), isSchemeLike(s[..<colon]) {
      let scheme = s[..<colon].lowercased()
      let rest = s[s.index(after: colon)...]
      if scheme == "http" || scheme == "https" {
        guard rest.hasPrefix("//") else { return search(s, searchTemplate) }
        return encode(s)
      }
      if scheme == "about" && s.lowercased() == "about:blank" { return URL(string: "about:blank") }
      // "host:port" without a scheme (localhost:3000, example.com:8080) is NOT a scheme
      if !looksLikeHostPort(s) { return nil }                   // javascript:, data:, file:, mailto:, ftp:, view-source: ... refused
    }
    if s.hasPrefix("//") { return search(s, searchTemplate) }  // protocol-relative input is ambiguous: treat as text
    if s.contains(" ") || s.contains("@") && !hostLike(s) { return search(s, searchTemplate) }
    if hostLike(s) {
      let h = hostPart(s).lowercased()
      let plain = h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || isIPv4(h) || h.hasPrefix("[")
      return encode((plain ? "http://" : "https://") + s)
    }
    return search(s, searchTemplate)
  }

  static func isSchemeLike(_ p: Substring) -> Bool {
    guard let f = p.first, f.isLetter else { return false }
    return p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
  }
  /// `localhost:3000/path`, `example.com:8080` — a port, not a scheme.
  static func looksLikeHostPort(_ s: String) -> Bool {
    guard let colon = s.firstIndex(of: ":") else { return false }
    let after = s[s.index(after: colon)...]
    let digits = after.prefix { $0.isNumber }
    return !digits.isEmpty && digits.count <= 5 && (after.dropFirst(digits.count).first.map { $0 == "/" || $0 == "?" || $0 == "#" } ?? true) && hostLike(String(s[..<colon]))
  }
  static func hostPart(_ s: String) -> String {
    var h = s
    if let i = h.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { h = String(h[..<i]) }
    if let i = h.lastIndex(of: ":"), !h.hasSuffix("]"), h[h.index(after: i)...].allSatisfy(\.isNumber) { h = String(h[..<i]) }
    return h
  }
  static func isIPv4(_ h: String) -> Bool {
    let p = h.split(separator: ".", omittingEmptySubsequences: false)
    return p.count == 4 && p.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
  }
  /// Looks like a host: localhost, IPv4, [IPv6], or labels with a TLD of 2+ letters.
  static func hostLike(_ s: String) -> Bool {
    let h = hostPart(s)
    if h.isEmpty || h.contains(" ") { return false }
    if h.lowercased() == "localhost" || isIPv4(h) { return true }
    if h.hasPrefix("[") && h.hasSuffix("]") { return true }
    let labels = h.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
    guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
    return labels.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
  }
  static func encode(_ s: String) -> URL? {
    if let u = URL(string: s), u.host != nil { return u }
    guard let c = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%"))), let u = URL(string: c), u.host != nil else { return nil }
    return u
  }
  static func search(_ q: String, _ template: String) -> URL? {
    var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+#?/:;@$,")
    guard let enc = q.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: template.replacingOccurrences(of: "%s", with: enc))
  }
}

/// What the engine may do with a navigation requested by a page or a click. Pure policy, enforced in WKNavigationDelegate.
public enum NavigationDecision: Equatable, Sendable {
  case allow
  case openExternally        // hand to the system (mailto:, tel:, other apps) — only for a real user click
  case block(String)
}
public enum NavigationPolicy {
  public static let webSchemes: Set<String> = ["http", "https"]
  public static func decide(url: URL?, userInitiated: Bool, isMainFrame: Bool) -> NavigationDecision {
    guard let url, let scheme = url.scheme?.lowercased() else { return .block("no scheme") }
    switch scheme {
    case "http", "https": return .allow
    case "about": return url.absoluteString.lowercased() == "about:blank" || url.absoluteString.lowercased() == "about:srcdoc" ? .allow : .block("about: page")
    case "blob": return .allow                                   // downloads / generated documents
    case "data": return isMainFrame ? .block("data: top-level navigation (phishing vector)") : .allow
    case "javascript": return .block("javascript: navigation")
    case "file": return .block("file: navigation from web content")
    case "ftp", "ws", "wss", "view-source", "chrome", "chrome-extension", "moz-extension": return .block("\(scheme): not supported")
    default:
      // other schemes (mailto, tel, facetime, zoommtg, slack, itms-apps...) launch OTHER apps: only after a real click on a main-frame link
      return userInitiated && isMainFrame ? .openExternally : .block("\(scheme): external app launch without user action")
    }
  }
}
