import Foundation

/// File-name rules for downloads (pure, testable).
public enum DownloadNames {
  /// A name that cannot escape the directory or hide as a dotfile / control name.
  public static func sanitize(_ suggested: String) -> String {
    var n = suggested.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "_")
    n = String(String.UnicodeScalarView(n.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
    n = n.trimmingCharacters(in: .whitespaces)
    while n.hasPrefix(".") { n.removeFirst() }
    if n.isEmpty { n = "download" }
    return String(n.prefix(120))
  }
  /// `name`, `name 2`, `name 3` ... never overwrites. `exists` is injectable for tests.
  public static func unique(_ name: String, exists: (String) -> Bool) -> String {
    if !exists(name) { return name }
    let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
    var i = 2
    while true { let c = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"; if !exists(c) { return c }; i += 1 }
  }
}
