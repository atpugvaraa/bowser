import BrowserCore
import Foundation

/// Why a tab may not be hibernated. Shown to the user ("explain why", master prompt §7).
public enum Protection: String, Sendable, CaseIterable {
  case active, audible, recentlyAudible, playingMedia, pictureInPicture, capturing, call, devTools, downloading, unsavedForm, upload, loading, userRule
}

/// Learns, per host, how long you typically leave a tab before coming back (EWMA of idle gaps). Bounded size.
public struct UsageModel: Sendable, Codable {
  struct Entry: Sendable, Codable { var gap: Double; var seq: Int }
  public private(set) var version = 1
  var entries: [String: Entry] = [:]
  var seq = 0
  public var alpha = 0.3
  public var maxHosts = 1000
  public init() {}
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let lossy = (try? c.decodeIfPresent([String: LossyEntry].self, forKey: .entries)) ?? [:]       // one bad entry must not discard the rest
    entries = lossy.compactMapValues { $0.value }
    seq = (try? c.decodeIfPresent(Int.self, forKey: .seq)) ?? 0
    alpha = (try? c.decodeIfPresent(Double.self, forKey: .alpha)) ?? 0.3
    maxHosts = max((try? c.decodeIfPresent(Int.self, forKey: .maxHosts)) ?? 1000, 10)
    entries = entries.filter { $0.value.gap.isFinite && $0.value.gap >= 0 }          // a damaged entry is dropped, not trusted
  }
  private struct LossyEntry: Decodable { let value: Entry?; init(from decoder: Decoder) throws { value = try? Entry(from: decoder) } }
  enum CodingKeys: String, CodingKey { case version, entries, seq, alpha, maxHosts }
  public var gaps: [String: Double] { entries.mapValues(\.gap) }
  private var safeAlpha: Double { alpha.isFinite ? min(max(alpha, 0.01), 1) : 0.3 }
  public mutating func recordReactivation(host: String, idleSeconds: Double) {
    guard idleSeconds.isFinite else { return }          // NaN/inf must never poison a host forever
    let g = max(idleSeconds, 0); seq += 1
    let prev = entries[host].flatMap { $0.gap.isFinite ? $0.gap : nil }
    entries[host] = Entry(gap: prev.map { $0 + safeAlpha * (g - $0) } ?? g, seq: seq)
    evictIfNeeded()
  }
  /// Right-censored observation: the tab has NOT come back after `idleSeconds` (e.g. it was hibernated and is still unused).
  /// Only ever raises the estimate, so learned gaps are not biased short by recording returning tabs alone.
  public mutating func recordNoReturn(host: String, idleSeconds: Double) {
    guard idleSeconds.isFinite, idleSeconds > 0 else { return }
    seq += 1
    if let e = entries[host], e.gap.isFinite { if idleSeconds > e.gap { entries[host] = Entry(gap: e.gap + safeAlpha * (idleSeconds - e.gap), seq: seq) } }
    else { entries[host] = Entry(gap: idleSeconds, seq: seq) }
    evictIfNeeded()
  }
  private mutating func evictIfNeeded() {
    if entries.count > maxHosts, let oldest = entries.min(by: { $0.value.seq < $1.value.seq })?.key { entries[oldest] = nil }
  }
  public func expectedGap(host: String?) -> Double? { host.flatMap { entries[$0] }.flatMap { $0.gap.isFinite ? $0.gap : nil } }
}

public struct PressureTable<T: Sendable & Codable>: Sendable, Codable {
  public var normal: T, warning: T, critical: T
  public init(normal: T, warning: T, critical: T) { self.normal = normal; self.warning = warning; self.critical = critical }
  public subscript(l: PressureLevel) -> T { switch l { case .normal: normal; case .warning: warning; case .critical: critical } }
}

/// All user-settable. Persist as JSON; always pass through `validated()` before use.
public struct PolicyConfig: Sendable, Codable {
  public var enabled = true                          // false = never hibernate by time; the live-tab budget still applies
  public var defaultGrace: TimeInterval = 60 * 60    // idle time before a tab becomes eligible
  public var minGrace: TimeInterval = 15 * 60        // floor at normal/warning pressure
  public var criticalFloor: TimeInterval = 5 * 60    // floor even under critical memory pressure
  public var gapFactor = 3.0                         // a habitual tab is kept live ~3x its usual return gap (catches ~95% of returns)
  public var coldGap: TimeInterval = 45 * 60         // break-even: tabs whose usual return gap exceeds this are "cold" and released early
  public var maxGrace: TimeInterval = 4 * 3600       // upper bound for habitual tabs
  public var taperWidth = 0.25                       // grace falls from habitual to minGrace across gap = coldGap ... coldGap*(1+taperWidth) (no cliff, little extra memory)
  public var pinnedMultiplier = 3.0
  public var liveConnectionMultiplier = 3.0         // grace multiplier for tabs with an open WebSocket/EventSource
  public var audibleGrace: TimeInterval = 10 * 60   // keep a tab live this long after its audio stops
  public var neverSleepHosts: [String] = []         // user list: tabs on these sites (and their subdomains) are never slept
  public var pressureScale = PressureTable<Double>(normal: 1.0, warning: 0.5, critical: 0.25)
  public var maxLive = PressureTable<Int>(normal: 60, warning: 40, critical: 20)
  /// A tab idle for less than this is never shed by the live-tab budget. Shrinks as memory pressure rises so a burst of
  /// recently used tabs can still be relieved when the Mac is actually struggling.
  public var budgetFloor = PressureTable<TimeInterval>(normal: 300, warning: 120, critical: 30)
  public init() {}

  /// Tolerant decoding: a saved file from an older/newer version (missing or extra keys) never fails and never resets the rest.
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func get<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
    enabled = get(.enabled, enabled); defaultGrace = get(.defaultGrace, defaultGrace); minGrace = get(.minGrace, minGrace)
    criticalFloor = get(.criticalFloor, criticalFloor); gapFactor = get(.gapFactor, gapFactor); coldGap = get(.coldGap, coldGap)
    maxGrace = get(.maxGrace, maxGrace); taperWidth = get(.taperWidth, taperWidth); pinnedMultiplier = get(.pinnedMultiplier, pinnedMultiplier)
    liveConnectionMultiplier = get(.liveConnectionMultiplier, liveConnectionMultiplier); audibleGrace = get(.audibleGrace, audibleGrace)
    pressureScale = get(.pressureScale, pressureScale); maxLive = get(.maxLive, maxLive); budgetFloor = get(.budgetFloor, budgetFloor)
    neverSleepHosts = get(.neverSleepHosts, neverSleepHosts)
  }
  enum CodingKeys: String, CodingKey {
    case enabled, defaultGrace, minGrace, criticalFloor, gapFactor, coldGap, maxGrace, taperWidth, pinnedMultiplier, liveConnectionMultiplier, audibleGrace, pressureScale, maxLive, budgetFloor, neverSleepHosts
  }

  /// Product default for a heavy multi-tab user (tuned on the simulator, see docs/results/policy-sim-*): tabs stay alive long,
  /// habitual tabs longer, pressure still shrinks everything. `init()` stays the neutral base used by unit tests.
  public static var relaxed: PolicyConfig {
    var c = PolicyConfig()
    c.minGrace = 45 * 60; c.defaultGrace = 90 * 60; c.coldGap = 90 * 60; c.gapFactor = 3; c.maxGrace = 6 * 3600; c.criticalFloor = 10 * 60
    c.maxLive = .init(normal: 100, warning: 70, critical: 40)
    return c
  }

  /// Lowercased bare host (no scheme/path/port/wildcard). Empty if it can't be a host.
  public static func normalizeHost(_ raw: String) -> String {
    var h = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
    if let i = h.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" }) { h = String(h[..<i]) }
    if h.hasPrefix("*.") { h.removeFirst(2) }
    if h.hasPrefix("www.") { h.removeFirst(4) }
    guard !h.isEmpty, h.count <= 253, h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }), !h.hasPrefix("."), !h.hasSuffix(".") else { return "" }
    return h
  }
  /// True if `host` is one of the user's never-sleep sites or a subdomain of one.
  public func isNeverSleep(host: String?) -> Bool {
    guard let h = host?.lowercased(), !h.isEmpty else { return false }
    return neverSleepHosts.contains { h == $0 || h.hasSuffix("." + $0) }
  }

  /// Clamp user input to sane values (a typo must never hibernate everything).
  public func validated() -> PolicyConfig {
    var c = self
    func fin(_ x: Double, _ d: Double) -> Double { x.isFinite ? x : d }
    c.minGrace = max(fin(c.minGrace, 15 * 60), 30)
    c.defaultGrace = max(fin(c.defaultGrace, 60 * 60), c.minGrace)
    c.criticalFloor = min(max(fin(c.criticalFloor, 5 * 60), 30), c.minGrace)
    c.gapFactor = min(max(fin(c.gapFactor, 3), 1), 10)
    c.coldGap = min(max(fin(c.coldGap, 45 * 60), 60), 7 * 86_400)
    c.taperWidth = min(max(fin(c.taperWidth, 0.25), 0.01), 2)
    c.maxGrace = min(max(fin(c.maxGrace, 4 * 3600), c.defaultGrace), 7 * 86_400)
    c.pinnedMultiplier = min(max(fin(c.pinnedMultiplier, 3), 1), 20)
    c.audibleGrace = min(max(fin(c.audibleGrace, 600), 0), 24 * 3600)
    c.liveConnectionMultiplier = min(max(fin(c.liveConnectionMultiplier, 3), 1), 20)
    c.neverSleepHosts = Array(Set(c.neverSleepHosts.map { PolicyConfig.normalizeHost($0) }.filter { !$0.isEmpty })).sorted().prefix(200).map { $0 }
    func sc(_ x: Double) -> Double { min(max(fin(x, 1), 0.05), 1) }
    c.pressureScale = .init(normal: sc(c.pressureScale.normal), warning: sc(c.pressureScale.warning), critical: sc(c.pressureScale.critical))
    func ml(_ x: Int) -> Int { max(x, 1) }
    c.maxLive = .init(normal: ml(c.maxLive.normal), warning: ml(c.maxLive.warning), critical: ml(c.maxLive.critical))
    func bf(_ x: Double, _ d: Double) -> Double { min(max(fin(x, d), 10), 3600) }
    let bn = bf(c.budgetFloor.normal, 300), bw = min(bf(c.budgetFloor.warning, 120), bn)
    c.budgetFloor = .init(normal: bn, warning: bw, critical: min(bf(c.budgetFloor.critical, 30), bw))   // tighter pressure never RAISES the floor
    return c
  }
}

public struct Decision: Sendable {
  public var hibernate: [TabID] = []                     // longest idle first
  public var protected: [TabID: [Protection]] = [:]
  public var overBudget = 0                              // live tabs beyond the budget that could NOT be shed (protected / too fresh)
}

public enum HibernationPolicy {
  public static func protections(_ t: TabInfo, now: Date? = nil, audibleGrace: TimeInterval = 0) -> [Protection] {
    var p: [Protection] = []
    if t.isActive { p.append(.active) }
    if t.isAudible { p.append(.audible) }
    if let n = now, let la = t.lastAudible, !t.isAudible, n.timeIntervalSince(la) < audibleGrace, n >= la { p.append(.recentlyAudible) }
    if t.isPlayingMedia { p.append(.playingMedia) }
    if t.isPictureInPicture { p.append(.pictureInPicture) }
    if t.isCapturing { p.append(.capturing) }
    if t.isInCall { p.append(.call) }
    if t.isDevToolsOpen { p.append(.devTools) }
    if t.isDownloading { p.append(.downloading) }
    if t.hasUnsavedForm { p.append(.unsavedForm) }
    if t.hasInflightUpload { p.append(.upload) }
    if t.isLoading { p.append(.loading) }
    if t.userProtected { p.append(.userRule) }
    return p
  }

  /// Idle time after which this tab becomes eligible, adapted to the user's habits and memory pressure.
  public static func grace(for t: TabInfo, pressure: PressureLevel, usage: UsageModel, config c: PolicyConfig) -> TimeInterval {
    var g = c.defaultGrace                           // unknown habits: the default
    if let gap = usage.expectedGap(host: t.host) {
      // Break-even rule: returning within ~coldGap is cheaper than a restore -> keep habitual tabs generously;
      // tabs you rarely come back to are released early.
      let habitual = min(max(gap * c.gapFactor, c.minGrace), c.maxGrace)
      if gap <= c.coldGap { g = habitual }
      else if gap < c.coldGap * (1 + c.taperWidth) { g = habitual + (c.minGrace - habitual) * ((gap - c.coldGap) / (c.coldGap * c.taperWidth)) }   // narrow taper, no cliff
      else { g = c.minGrace }
    }
    if t.isPinned { g *= c.pinnedMultiplier }
    if t.hasLiveConnection { g *= c.liveConnectionMultiplier }
    g = min(g, 7 * 86_400)                           // multipliers can never make grace effectively infinite
    g *= c.pressureScale[pressure]
    return max(g, max(c.minGrace * c.pressureScale[pressure], c.criticalFloor))   // the floor shrinks with pressure, never below criticalFloor
  }

  /// `lastWake`: when the Mac last woke from sleep. Time asleep is not idle time, so a wake never mass-hibernates tabs.
  public static func evaluate(tabs rawTabs: [TabInfo], pressure: PressureLevel, usage: UsageModel, now: Date,
                              lastWake: Date? = nil, config raw: PolicyConfig = .init()) -> Decision {
    let c = raw.validated()
    var d = Decision()

    // Merge duplicate ids: protected if ANY copy is protected; freshest activity wins.
    var byID: [TabID: TabInfo] = [:], extra: [TabID: Set<Protection>] = [:]
    for t in rawTabs {
      extra[t.id, default: []].formUnion(protections(t, now: now, audibleGrace: c.audibleGrace))
      if c.isNeverSleep(host: t.host) { extra[t.id, default: []].insert(.userRule) }          // the user's never-sleep sites, enforced by the policy itself
      if let o = byID[t.id] { if t.lastActive > o.lastActive { byID[t.id] = t } } else { byID[t.id] = t }
    }
    var live = 0
    var candidates: [(t: TabInfo, idle: TimeInterval)] = []
    for t in byID.values where t.liveness == .live {
      live += 1
      let p = extra[t.id].map { Protection.allCases.filter($0.contains) } ?? []
      if !p.isEmpty { d.protected[t.id] = p; continue }
      let since = max(t.lastActive, lastWake ?? .distantPast)
      candidates.append((t, max(now.timeIntervalSince(since), 0)))
    }
    candidates.sort { $0.idle != $1.idle ? $0.idle > $1.idle : $0.t.id.raw.uuidString < $1.t.id.raw.uuidString }

    var chosen = Set<TabID>()
    if c.enabled {
      for x in candidates where x.idle >= grace(for: x.t, pressure: pressure, usage: usage, config: c) {
        chosen.insert(x.t.id); d.hibernate.append(x.t.id)
      }
    }
    // Hard budget on live tabs: shed further tabs, unpinned before pinned, longest idle first; never protected ones.
    let budget = c.maxLive[pressure]
    var remaining = live - chosen.count
    // Over budget: unpinned first; then the tab whose own grace would expire SOONEST (cold tabs before habitual ones); ties by id.
    func timeLeft(_ x: (t: TabInfo, idle: TimeInterval)) -> TimeInterval { grace(for: x.t, pressure: pressure, usage: usage, config: c) - x.idle }
    for x in candidates.sorted(by: { l, r in
      if l.t.isPinned != r.t.isPinned { return !l.t.isPinned }
      let a = timeLeft(l), b = timeLeft(r)
      return a != b ? a < b : l.t.id.raw.uuidString < r.t.id.raw.uuidString })
    where remaining > budget && !chosen.contains(x.t.id) && x.idle >= c.budgetFloor[pressure] {
      chosen.insert(x.t.id); d.hibernate.append(x.t.id); remaining -= 1
    }
    d.overBudget = max(remaining - budget, 0)
    return d
  }
}
