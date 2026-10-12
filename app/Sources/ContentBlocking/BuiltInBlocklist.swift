import Foundation

/// Conservative built-in rules: only THIRD-PARTY requests to well-known ad/tracker networks. First-party requests are never touched.
/// Video sites are always exempt (see `BlockingSettings.alwaysAllowed`) so playback can't be broken by a list.
public enum BuiltInBlocklist {
  static let hosts: [String] = [
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "adnxs.com", "adsrvr.org",
    "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "scorecardresearch.com", "quantserve.com", "rubiconproject.com",
    "pubmatic.com", "openx.net", "casalemedia.com", "moatads.com", "adsafeprotected.com", "serving-sys.com", "2mdn.net",
    "amazon-adsystem.com", "advertising.com", "bluekai.com", "demdex.net", "krxd.net", "mathtag.com", "yieldmo.com", "smartadserver.com",
  ]
  public static var rules: String {
    let items = hosts.map { h -> String in
      let esc = h.replacingOccurrences(of: ".", with: "\\\\.")
      return #"{"trigger":{"url-filter":"^https?://([^/:]+\\.)?\#(esc)[:/]","load-type":["third-party"]},"action":{"type":"block"}}"#
    }
    return "[" + items.joined(separator: ",") + "]"
  }
}

/// User-facing content-blocking settings (stored as one opaque setting).
public struct BlockingSettings: Codable, Equatable, Sendable {
  public var enabled = false                       // off until the user turns it on
  public var allowlist: [String] = []              // sites where blocking is off (user)
  public init() {}
  /// Never blocked on these, whatever the lists say: video must keep working.
  public static let alwaysAllowed = ["netflix.com", "nflxvideo.net", "nflximg.net", "youtube.com", "googlevideo.com", "ytimg.com", "primevideo.com", "amazon.com", "media-amazon.com", "aiv-cdn.net"]
  public var effectiveAllowlist: [String] { Array(Set(Self.alwaysAllowed + allowlist.map { Self.normalize($0) }.filter { !$0.isEmpty })).sorted() }
  public static func normalize(_ raw: String) -> String {
    var h = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
    if let i = h.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" }) { h = String(h[..<i]) }
    if h.hasPrefix("www.") { h.removeFirst(4) }
    guard !h.isEmpty, h.count <= 253, h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return "" }
    return h
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
    allowlist = Array(((try? c.decodeIfPresent([String].self, forKey: .allowlist)) ?? []).map(Self.normalize).filter { !$0.isEmpty }.prefix(200))
  }
  enum CodingKeys: String, CodingKey { case enabled, allowlist }
}
