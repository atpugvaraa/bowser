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
  public static func words(_ q: String) -> [String] { Fold.text(q).split(whereSeparator: { $0.isWhitespace }).map(String.init) }
  /// True if `w` occurs in `text` at the start of a word (after any non-alphanumeric character).
  static func startsWord(_ text: String, _ w: String) -> Bool {
    var from = text.startIndex
    while let r = text.range(of: w, range: from..<text.endIndex) {
      if r.lowerBound == text.startIndex || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber) { return true }
      from = text.index(after: r.lowerBound)
    }
    return false
  }
  /// nil if some word is missing; else a score (higher = better).
  public static func score(_ c: QuickCandidate, words: [String]) -> Double? {
    guard !words.isEmpty else { return Double(c.recency) }
    let t = Fold.text(c.title), u = Fold.text(c.url)
    let host = Fold.text(URL(string: c.url)?.host ?? "")
    var total = 0.0
    for w in words {
      var s = 0.0
      if t.hasPrefix(w) { s = 6 } else if startsWord(t, w) { s = 5 } else if t.contains(w) { s = 3 }
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
    // Two OPEN tabs on one URL both stay reachable; any other source for a URL that an open tab already shows is redundant.
    var openURLs = Set<String>()
    for (c, _) in scored where c.kind == .openTab { openURLs.insert(c.url) }
    var seen = Set<String>()
    var out: [QuickCandidate] = []
    for (c, _) in scored {
      let key: String
      if c.kind == .openTab { key = "tab:" + (c.tab.map { "\($0.raw)" } ?? c.url) }
      else if openURLs.contains(c.url) { continue }
      else { key = c.url }
      if seen.insert(key).inserted { out.append(c); if out.count >= limit { break } }
    }
    return out
  }
}
