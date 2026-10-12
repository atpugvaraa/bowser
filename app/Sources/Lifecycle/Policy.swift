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
  public var gaps: [String: Double] { entries.mapValues(\.gap) }
  public mutating func recordReactivation(host: String, idleSeconds: Double) {
    guard idleSeconds.isFinite else { return }          // NaN/inf must never poison a host forever
    let g = max(idleSeconds, 0); seq += 1
    let prev = entries[host]?.gap
    entries[host] = Entry(gap: prev.map { $0 + alpha * (g - $0) } ?? g, seq: seq)
    if entries.count > maxHosts, let oldest = entries.min(by: { $0.value.seq < $1.value.seq })?.key { entries[oldest] = nil }
  }
  public func expectedGap(host: String?) -> Double? { host.flatMap { entries[$0]?.gap } }
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
  public var gapFactor = 1.5                         // keep a tab live ~1.5x its usual idle gap
  public var pinnedMultiplier = 3.0
  public var audibleGrace: TimeInterval = 10 * 60   // keep a tab live this long after its audio stops
  public var pressureScale = PressureTable<Double>(normal: 1.0, warning: 0.5, critical: 0.25)
  public var maxLive = PressureTable<Int>(normal: 60, warning: 40, critical: 20)
  public init() {}

  /// Clamp user input to sane values (a typo must never hibernate everything).
  public func validated() -> PolicyConfig {
    var c = self
    func fin(_ x: Double, _ d: Double) -> Double { x.isFinite ? x : d }
    c.minGrace = max(fin(c.minGrace, 15 * 60), 30)
    c.defaultGrace = max(fin(c.defaultGrace, 60 * 60), c.minGrace)
    c.criticalFloor = min(max(fin(c.criticalFloor, 5 * 60), 30), c.minGrace)
    c.gapFactor = min(max(fin(c.gapFactor, 1.5), 1), 10)
    c.pinnedMultiplier = min(max(fin(c.pinnedMultiplier, 3), 1), 20)
    c.audibleGrace = min(max(fin(c.audibleGrace, 600), 0), 24 * 3600)
    func sc(_ x: Double) -> Double { min(max(fin(x, 1), 0.05), 1) }
    c.pressureScale = .init(normal: sc(c.pressureScale.normal), warning: sc(c.pressureScale.warning), critical: sc(c.pressureScale.critical))
    func ml(_ x: Int) -> Int { max(x, 1) }
    c.maxLive = .init(normal: ml(c.maxLive.normal), warning: ml(c.maxLive.warning), critical: ml(c.maxLive.critical))
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
    var g = c.defaultGrace
    if let gap = usage.expectedGap(host: t.host) { g = min(max(gap * c.gapFactor, c.minGrace), c.defaultGrace) }
    if t.isPinned { g *= c.pinnedMultiplier }
    g *= c.pressureScale[pressure]
    return max(g, pressure == .critical ? c.criticalFloor : c.minGrace)
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
    for x in candidates.sorted(by: { $0.t.isPinned != $1.t.isPinned ? !$0.t.isPinned : $0.idle > $1.idle })
    where remaining > budget && !chosen.contains(x.t.id) && x.idle >= c.criticalFloor {
      chosen.insert(x.t.id); d.hibernate.append(x.t.id); remaining -= 1
    }
    d.overBudget = max(remaining - budget, 0)
    return d
  }
}
