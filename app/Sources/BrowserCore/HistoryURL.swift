import Foundation

/// What may be stored in history / shown in the palette. Secrets must not end up in plaintext history, quick-open results or backups.
public enum HistoryURL {
  /// Query parameter names whose presence means the URL carries a credential/one-time secret.
  static let sensitive: Set<String> = ["token", "access_token", "id_token", "refresh_token", "auth", "authorization", "code", "key", "apikey", "api_key", "password", "passwd", "pwd", "secret", "session", "sessionid", "sid", "sig", "signature", "otp", "magic", "ticket", "jwt", "bearer", "x-amz-signature", "x-amz-credential"]

  /// The URL to store for history, or nil if it must NOT be recorded (non-web scheme, or it carries a secret).
  /// Userinfo (`user:pass@`) and the fragment (`#access_token=…`, SPA routes) are always dropped.
  public static func forHistory(_ u: URL) -> String? {
    guard let sc = u.scheme?.lowercased(), sc == "http" || sc == "https", var c = URLComponents(url: u, resolvingAgainstBaseURL: false), c.host != nil else { return nil }
    c.user = nil; c.password = nil; c.fragment = nil
    if let items = c.queryItems, items.contains(where: { sensitive.contains($0.name.lowercased()) }) { return nil }
    return c.string
  }
  /// Bookmarks are an explicit user choice, so the query is kept (it may be the whole point), but credentials in the URL are not.
  public static func forBookmark(_ u: URL) -> String? {
    guard let sc = u.scheme?.lowercased(), sc == "http" || sc == "https", var c = URLComponents(url: u, resolvingAgainstBaseURL: false), c.host != nil else { return nil }
    c.user = nil; c.password = nil
    return c.string
  }
}

/// Text from a web page shown in native dialogs: bounded, no control or bidirectional-override characters.
public enum DialogText {
  public static func sanitize(_ s: String, maxLines: Int = 20, maxChars: Int = 1000) -> String {
    let cleaned = s.unicodeScalars.filter { sc in
      if sc == "\n" || sc == "\t" { return true }
      switch sc.properties.generalCategory { case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return false; default: return true }
    }
    var text = String(String.UnicodeScalarView(cleaned)).replacingOccurrences(of: "\t", with: "    ")
    if text.count > maxChars { text = String(text.prefix(maxChars)) + "…" }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > maxLines { text = lines.prefix(maxLines).joined(separator: "\n") + "\n…" }
    return text
  }
}
