import AppKit
import Foundation
import WebKit

/// Website icons for the tab list. Looks the icon up on the loaded page (`<link rel=icon>`), falls back to /favicon.ico, downloads it with an ephemeral
/// session (no cookies), shrinks it to 32x32 and keeps it in memory and in the app's data folder (so sleeping tabs show icons after a restart).
/// A site with no usable icon gets none: the tab list then shows an empty square.
@MainActor
final class FaviconStore {
  private var cache: [String: NSImage] = [:]
  private var attempted: Set<String> = []
  private var inflight = 0
  private let dir: URL
  var onUpdate: (() -> Void)?

  init(dir: URL) { self.dir = dir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

  private func fileURL(_ host: String) -> URL { dir.appendingPathComponent(host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } + ".png") }

  func image(for host: String) -> NSImage? {
    if let i = cache[host] { return i }
    if let i = NSImage(contentsOf: fileURL(host)), host.count < 254 { cache[host] = i; return i }
    return nil
  }

  /// True if nobody has tried this host yet in this run and no icon is stored.
  func wants(_ host: String) -> Bool { !host.isEmpty && !attempted.contains(host) && image(for: host) == nil && inflight < 3 }

  func fetch(host: String, from web: WKWebView?, origin: String) async {
    guard wants(host) else { return }
    attempted.insert(host); inflight += 1; defer { inflight -= 1 }
    var candidates: [URL] = []
    if let web, let href = try? await web.evaluateJavaScript("(()=>{const l=[...document.querySelectorAll('link[rel~=\"icon\"],link[rel=\"apple-touch-icon\"]')];return l.length?l[l.length-1].href:''})()") as? String, let u = URL(string: href) { candidates.append(u) }
    if let u = URL(string: origin + "/favicon.ico") { candidates.append(u) }
    for u in candidates where Self.allowed(u, pageHost: host) {
      if let img = await download(u) { cache[host] = img; if let png = img.pngData { try? png.write(to: fileURL(host), options: .atomic) }; onUpdate?(); return }
    }
  }

  /// Only https icons (or http for local pages); never file:, data: or other schemes.
  static func allowed(_ u: URL, pageHost: String) -> Bool {
    guard let s = u.scheme?.lowercased(), u.host != nil else { return false }
    return s == "https" || (s == "http" && (pageHost == "localhost" || pageHost == "127.0.0.1"))
  }

  private func download(_ u: URL) async -> NSImage? {
    let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 8; cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false
    let session = URLSession(configuration: cfg); defer { session.finishTasksAndInvalidate() }
    guard let (data, resp) = try? await session.data(from: u), (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 0, data.count <= 262_144, let img = NSImage(data: data), img.size.width > 0, img.size.width <= 1024 else { return nil }
    let out = NSImage(size: NSSize(width: 32, height: 32)); out.lockFocus(); img.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1); out.unlockFocus()
    return out
  }
}
extension NSImage {
  var pngData: Data? { tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } }
}
