import Foundation

/// Ranking for the ⌘K quick-open palette (pure). Every query word must appear in the title or URL; better matches rank higher.
public struct QuickCandidate: Equatable, Sendable {
  public enum Kind: Int, Sendable { case openTab = 0, bookmark, closedTab, history }
  public var kind: Kind, title: String, url: String
  public var recency: Double          // 0 (old) ... 1 (just now)
  public var tab: TabID?              // for open/closed tabs
  public init(kind: Kind, title: String, url: String, recency: Double = 0, tab: TabID? = nil) { self.kind = kind; self.title = title; self.url = url; self.recency = recency; self.tab = tab }
}
public enum QuickSearch {
  public static func words(_ q: String) -> [String] { q.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
  /// nil if some word is missing; else a score (higher = better).
  public static func score(_ c: QuickCandidate, words: [String]) -> Double? {
    guard !words.isEmpty else { return Double(c.recency) }
    let t = c.title.lowercased(), u = c.url.lowercased()
    let host = URL(string: c.url)?.host?.lowercased() ?? ""
    var total = 0.0
    for w in words {
      var s = 0.0
      if t.hasPrefix(w) { s = 6 } else if t.contains(" " + w) { s = 5 } else if t.contains(w) { s = 3 }
      if host.hasPrefix(w) || host.contains("." + w) { s = max(s, 5) } else if u.contains(w) { s = max(s, 1.5) }
      if s == 0 { return nil }
      total += s
    }
    let kindBonus: Double = [3, 1.5, 2, 0][c.kind.rawValue]                     // open tab > closed tab (restores your page state) > bookmark > history
    return total + kindBonus + c.recency * 2
  }
  public static func rank(_ cands: [QuickCandidate], query: String, limit: Int = 30) -> [QuickCandidate] {
    let w = words(query)
    var scored: [(QuickCandidate, Double)] = []
    for c in cands { if let sc = score(c, words: w) { scored.append((c, sc)) } }
    scored.sort { (l: (QuickCandidate, Double), r: (QuickCandidate, Double)) -> Bool in
      if l.1 != r.1 { return l.1 > r.1 }
      return l.0.url < r.0.url
    }
    var seen = Set<String>()                                                    // same URL from several sources: keep the best-ranked
    var out: [QuickCandidate] = []
    for (c, _) in scored where seen.insert(c.url).inserted { out.append(c); if out.count >= limit { break } }
    return out
  }
}
