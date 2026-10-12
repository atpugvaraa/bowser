import BrowserCore
import Foundation

public struct PassReport: Sendable {
  public var hibernated: [TabID] = []
  public var skippedBecauseActivated: [TabID] = []      // chosen by the policy but became active while the pass was running
  public var protected: [TabID: [Protection]] = [:]
  public var overBudget = 0
  public var evaluationMs = 0.0
  public var unresponsive: [TabID] = []
}

/// Orchestrates tabs <-> policy: collects real signals, asks the pure policy what to do, re-checks the world, applies it,
/// and learns the user's habits. Engine-agnostic (EngineTab), clock and pressure injected for tests.
@MainActor
public final class LifecycleManager {
  public var config: PolicyConfig
  public private(set) var usage: UsageModel
  private var tabs: [TabID: any EngineTab] = [:]
  private var host: [TabID: String] = [:]
  private var lastActive: [TabID: Date] = [:]
  private var lastDeactivated: [TabID: Date] = [:]
  private var lastWake: Date?
  private var active: TabID?
  private var visible: Set<TabID> = []          // selected in ANY window (all stay protected; `active` is the focused one)
  private let clock: () -> Date
  private let pressure: () -> PressureLevel

  public init(config: PolicyConfig = .relaxed, usage: UsageModel = UsageModel(), clock: @escaping () -> Date = Date.init, pressure: @escaping () -> PressureLevel = { .normal }) {
    self.config = config; self.usage = usage; self.clock = clock; self.pressure = pressure
  }

  public func register(_ tab: any EngineTab, host: String?, lastActive: Date? = nil) {
    tabs[tab.id] = tab; self.host[tab.id] = host ?? ""; self.lastActive[tab.id] = lastActive ?? clock()
  }
  public func unregister(_ id: TabID) { tabs[id] = nil; host[id] = nil; lastActive[id] = nil; lastDeactivated[id] = nil; visible.remove(id); if active == id { active = nil } }
  public func noteWake(at: Date? = nil) { lastWake = at ?? clock() }       // sleep time is not idle time
  public var activeTab: TabID? { active }
  /// Tabs currently shown in any window. They are never hibernated; the focused one is `activate`d separately.
  public func setVisible(_ ids: Set<TabID>) {
    let now = clock()
    for gone in visible.subtracting(ids) where gone != active { lastActive[gone] = now; lastDeactivated[gone] = now }   // idle clock starts when it stops being shown
    visible = ids
    for (id, t) in tabs { t.isActive = ids.contains(id) || id == active }
  }
  public func lastActiveDate(of id: TabID) -> Date? { lastActive[id] }
  public func isRegistered(_ id: TabID) -> Bool { tabs[id] != nil }
  public var liveCount: Int { tabs.values.filter { $0.isLive }.count }

  /// The focused tab lost focus without another taking its place (e.g. its window closed). Starts its idle clock.
  public func deactivate(_ id: TabID) {
    guard active == id else { return }
    let now = clock(); active = nil; lastDeactivated[id] = now; lastActive[id] = now
    if !visible.contains(id) { tabs[id]?.isActive = false }
  }

  /// The user switched to `id` (resumes it if hibernated). Records how long it sat idle (the habit signal) and fixes `isActive`.
  public func activate(_ id: TabID) {
    guard let t = tabs[id] else { return }
    let now = clock()
    if let prev = active, prev != id { if !visible.contains(prev) { tabs[prev]?.isActive = false }; lastDeactivated[prev] = now; lastActive[prev] = now }
    if let ld = lastDeactivated[id], let h = host[id], !h.isEmpty { usage.recordReactivation(host: h, idleSeconds: now.timeIntervalSince(ld)) }
    active = id; lastActive[id] = now; lastDeactivated[id] = nil
    t.isActive = true
    t.ensureLiveView()
  }

  /// One policy pass. Safe against slow/hung tabs (signals have timeouts) and against the user switching tabs mid-pass.
  public func pass(signalTimeout: TimeInterval = 1.5) async -> PassReport {
    var report = PassReport()
    let now = clock(); let level = pressure()
    var infos: [TabInfo] = []
    let ids = Array(tabs.keys).sorted { $0.raw.uuidString < $1.raw.uuidString }
    for id in ids {
      guard let t = tabs[id] else { continue }               // may be unregistered while we await
      var ti = TabInfo(id: id, host: host[id], lastActive: lastActive[id] ?? now)
      ti.liveness = t.isLive ? .live : .hibernated
      if t.isLive {
        let s = await t.signals(timeout: signalTimeout)
        ti.isLoading = s.isLoading; ti.isPlayingMedia = s.isPlayingMedia; ti.isCapturing = s.isCapturing
        ti.hasUnsavedForm = s.hasDirtyForm; ti.hasLiveConnection = s.hasLiveConnection
        if s.isUnresponsive { report.unresponsive.append(id) }
      }
      infos.append(ti)
    }
    for i in infos.indices { infos[i].isActive = (infos[i].id == active) || visible.contains(infos[i].id) }          // freshest truth, not the pre-await value
    let t0 = Date()
    let d = HibernationPolicy.evaluate(tabs: infos, pressure: level, usage: usage, now: now, lastWake: lastWake, config: config)
    report.evaluationMs = Date().timeIntervalSince(t0) * 1000
    report.protected = d.protected; report.overBudget = d.overBudget
    for id in d.hibernate {
      guard let t = tabs[id] else { continue }
      if id == active || visible.contains(id) || t.isActive { report.skippedBecauseActivated.append(id); continue }   // user switched during the pass
      if t.hibernate(force: false) { report.hibernated.append(id) } else { report.skippedBecauseActivated.append(id) }
    }
    return report
  }

  /// Sleep one tab right now unless a HARD protection applies (media playing, capture, download, dirty form...). Used when a
  /// window closes: its tabs sleep immediately instead of waiting for the idle timer. Returns true if it was hibernated.
  public func sleepNow(_ id: TabID, signalTimeout: TimeInterval = 1.0) async -> Bool {
    guard let t = tabs[id], t.isLive, !visible.contains(id), id != active else { return false }
    let s = await t.signals(timeout: signalTimeout)
    if s.isUnresponsive { return false }                  // can't tell whether media/a call is running: do not guess
    var ti = TabInfo(id: id, host: host[id], lastActive: lastActive[id] ?? clock())
    ti.isLoading = s.isLoading; ti.isPlayingMedia = s.isPlayingMedia; ti.isCapturing = s.isCapturing; ti.hasUnsavedForm = s.hasDirtyForm
    if !HibernationPolicy.protections(ti).isEmpty { return false }
    if visible.contains(id) || id == active { return false }          // user may have switched during the await
    return t.hibernate(force: false)
  }
}
