import BrowserCore
import Foundation
import Lifecycle
import Persistence

/// Creates engine tabs (WebKit in the app, fakes in tests). Tabs must start HIBERNATED (no view/process) until ensureLiveView().
@MainActor
public protocol TabFactory: AnyObject {
  func makeTab(id: TabID, url: URL?, profile: ProfileID, restoredState: Data?) -> any EngineTab
  /// A page asked to open `url` in a new tab (window.open / target=_blank). The engine opens it next to the source tab.
  var linkOpenHandler: ((_ from: TabID, _ url: URL) -> Void)? { get set }
}

/// The core engine facade a UI talks to. Owns the model, the session store, the lifecycle manager and the engine tabs, and keeps
/// them consistent: every mutation ends in `reconcile()` (engine tabs mirror the model, incl. profile) and a debounced save.
/// Rules: closing never destroys (archive + saved state); closing a window sleeps its tabs (unless media/capture/etc.);
/// launch is lazy (only visible tabs are live); a tab always runs under the data store of its space's profile.
@MainActor
public final class BrowserEngine {
  public private(set) var state: BrowserState
  public let lifecycle: LifecycleManager
  public var onChange: (() -> Void)?
  private let session: SessionManager
  private let factory: TabFactory
  private var tabs: [TabID: any EngineTab] = [:]
  private var tabProfile: [TabID: ProfileID] = [:]
  private var unreadBlobs: Set<TabID> = []        // restore state could not be READ: never overwrite it from a fresh, shorter history
  private var maintenanceTimer: Timer?
  private var lastStateSave: Date = .distantPast
  private var lastPrune: Date = .distantPast

  public init(session: SessionManager, state: BrowserState, factory: TabFactory, lifecycle: LifecycleManager = LifecycleManager()) {
    self.session = session; self.state = state; self.factory = factory; self.lifecycle = lifecycle
    factory.linkOpenHandler = { [weak self] from, url in self?.openLink(from: from, url: url) }
    reconcile()
    syncVisible()                                  // lazy launch: only tabs selected in some window come alive
  }

  public func tab(_ id: TabID) -> (any EngineTab)? { tabs[id] }
  public var liveCount: Int { lifecycle.liveCount }

  // MARK: spaces / windows
  @discardableResult public func addSpace(name: String, profile: ProfileID) -> SpaceID { let s = state.addSpace(name: name, profile: profile); commit(); return s }
  @discardableResult public func deleteSpace(_ id: SpaceID) -> Bool { let r = state.deleteSpace(id) != nil; commit(); return r }
  @discardableResult public func openWindow(space: SpaceID) -> WindowID? {
    let w = state.openWindow(space: space); commit()
    if let w, let t = state.windows[w]?.selected { lifecycle.activate(t) }
    return w
  }
  /// Closing a window never closes tabs (they are views onto spaces); its tab sleeps unless a hard protection applies.
  public func closeWindow(_ id: WindowID) {
    let shown = state.windows[id]?.selected
    state.closeWindow(id); commit()
    if let shown, state.windowShowing(shown) == nil {
      lifecycle.deactivate(shown)
      Task { @MainActor in
        if let t = tabs[shown] { persistState(shown, t) }
        _ = await lifecycle.sleepNow(shown)
      }
    }
  }
  public func switchSpace(window: WindowID, to space: SpaceID) {
    state.switchSpace(window: window, to: space); commit()
    if let t = state.windows[window]?.selected { lifecycle.activate(t) }
  }

  // MARK: tabs
  @discardableResult public func newTab(in space: SpaceID, url: String, title: String = "", window: WindowID? = nil) -> TabID? {
    guard let id = state.addTab(in: space, url: url, title: title) else { return nil }
    commit()
    if let w = window { _ = select(tab: id, in: w) }
    return id
  }
  /// Closing sleeps: the tab goes to the archive with its restore state saved; its view/process is torn down (media stops).
  /// A never-used blank tab (about:blank) has nothing to recover, so it is not archived.
  public func closeTab(_ id: TabID) {
    let blank = state.tabs[id]?.url == "about:blank" && (tabs[id]?.currentURL?.absoluteString ?? "about:blank") == "about:blank"
    if let t = tabs[id] { syncOne(id, t); if !blank { persistState(id, t) } }
    state.closeTab(id)
    if blank { state.purge(id) }
    commit()                                       // reconcile() sleeps (force) and unregisters the engine tab; visible neighbours come alive
  }
  @discardableResult public func restoreTab(_ id: TabID, confirmedCrossProfile: Bool = false) -> RestoreResult {
    let r = state.restoreTab(id, confirmedCrossProfile: confirmedCrossProfile)
    if case .restored = r { commit() }
    return r
  }
  /// The only way a tab is really removed (and its saved history with it).
  public func purge(_ id: TabID) { state.purge(id); session.persistTabState(id, nil); commit() }
  /// Drop archive entries older than `cutoff` and their saved history.
  public func purgeArchive(olderThan cutoff: Date) { var kept: [TabID] = []; state.purgeArchive(olderThan: cutoff, keepingBlobsFor: &kept); commit(); pruneBlobs() }
  /// Moving across profiles needs `confirmedCrossProfile`; once moved, the tab is rebuilt under the destination profile's data store.
  @discardableResult public func moveTab(_ id: TabID, to space: SpaceID, confirmedCrossProfile: Bool = false) -> MoveResult {
    let r = state.moveTab(id, to: space, confirmedCrossProfile: confirmedCrossProfile); commit(); return r
  }
  @discardableResult public func detachTab(_ id: TabID) -> WindowID? {
    let w = state.detachTab(id); commit(); if w != nil { lifecycle.activate(id) }; return w
  }

  /// Select a tab in a window. If another window already shows it, the UI should focus that window (returned).
  @discardableResult public func select(tab: TabID, in window: WindowID) -> SelectResult {
    let r = state.select(tab: tab, in: window)
    if r == .selected { commit(); lifecycle.activate(tab) }
    return r
  }

  // MARK: lifecycle
  /// Call from a timer / on memory-pressure change.
  public func maintenance() async -> PassReport {
    let r = await lifecycle.pass()
    for id in r.hibernated { if let t = tabs[id] { persistState(id, t) } }
    let now = Date()
    if now.timeIntervalSince(lastStateSave) > 300 {                       // refresh saved history of live tabs (crash insurance)
      lastStateSave = now; syncFromTabs()
      for (id, t) in tabs where t.isLive { persistState(id, t) }
      session.scheduleSave(state)
    }
    session.rotateBackupIfDue()
    if now.timeIntervalSince(lastPrune) > 3600 { lastPrune = now; pruneBlobs(); try? EngineSettings.saveUsage(lifecycle.usage, to: session) }      // learned habits survive a crash too
    return r
  }
  public func startMaintenance(every seconds: TimeInterval = 30) {
    maintenanceTimer?.invalidate()
    maintenanceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in Task { @MainActor in _ = await self?.maintenance() } }
  }
  public func stopMaintenance() { maintenanceTimer?.invalidate(); maintenanceTimer = nil }
  public func noteWake() { lifecycle.noteWake() }
  /// Quit: write everything now. Throws if the model cannot be written (the caller must not claim a clean shutdown).
  public func shutdown() throws {
    syncFromTabs()
    for (id, t) in tabs { persistState(id, t) }
    try session.save(state)
    try? EngineSettings.saveUsage(lifecycle.usage, to: session)             // learned habits survive a restart
    _ = try? session.rotateBackup()
  }

  // MARK: settings
  public var policy: PolicyConfig { lifecycle.config }
  /// Apply and persist the user's hibernation settings (validated: a typo can never hibernate everything).
  public func updatePolicy(_ cfg: PolicyConfig) throws {
    lifecycle.config = cfg.validated()
    try EngineSettings.savePolicy(lifecycle.config, to: session)
  }

  /// Add/remove a site from the never-sleep list (matches the domain and its subdomains). Returns the new state (true = never sleeps).
  @discardableResult public func toggleNeverSleep(host: String) throws -> Bool {
    var c = lifecycle.config; let h = PolicyConfig.normalizeHost(host)
    guard !h.isEmpty else { return false }
    let nowOn: Bool
    if let i = c.neverSleepHosts.firstIndex(of: h) { c.neverSleepHosts.remove(at: i); nowOn = false } else { c.neverSleepHosts.append(h); nowOn = true }
    try updatePolicy(c); return nowOn
  }

  // MARK: navigation (address bar, toolbar)
  /// What the user typed in the address bar. Returns false if the input was refused (e.g. javascript:, file:).
  @discardableResult public func navigate(tab id: TabID, input: String, searchTemplate: String = URLInput.defaultSearch) -> Bool {
    guard let t = tabs[id], let url = URLInput.resolve(input, searchTemplate: searchTemplate) else { return false }
    t.load(url); lifecycle.activate(id); return true
  }
  /// Reopen the most recently closed tab (the archive is the "recently closed" list).
  @discardableResult public func reopenLastClosed(confirmedCrossProfile: Bool = false) -> RestoreResult {
    guard let last = state.archive.last else { return .notFound }
    return restoreTab(last.id, confirmedCrossProfile: confirmedCrossProfile)
  }
  /// Open a link requested by a page next to its source tab and show it in the window that shows the source.
  public func openLink(from source: TabID, url: URL) {
    guard let rec = state.tabs[source], let space = state.space(rec.space) else { return }
    let window = state.windows.values.first { $0.selected == source }?.id
    _ = newTab(in: space.id, url: url.absoluteString, window: window)
  }
  private func tabChanged(_ id: TabID) {
    guard let t = tabs[id] else { return }
    syncOne(id, t); session.scheduleSave(state); onChange?()
  }

  // MARK: internals
  private func commit() { reconcile(); syncVisible(); syncFromTabs(); session.scheduleSave(state); onChange?() }
  private func persistState(_ id: TabID, _ t: any EngineTab) {
    if unreadBlobs.contains(id) { return }          // an unreadable saved history is never replaced by a newer, shorter one
    if let d = t.captureState() { session.persistTabState(id, d) }
  }
  private func syncVisible() {
    let vis = state.visibleTabs
    for t in vis { tabs[t]?.ensureLiveView() }      // anything a window shows must be live (also after close/deleteSpace picks a neighbour)
    lifecycle.setVisible(vis)
  }
  private func syncOne(_ id: TabID, _ t: any EngineTab) {
    state.updateTab(id, url: t.currentURL?.absoluteString, title: t.currentTitle, lastActive: lifecycle.lastActiveDate(of: id))
  }
  /// Copy live URL / title / last-active into the model so saves and the archive hold what the user actually saw.
  private func syncFromTabs() { for (id, t) in tabs { syncOne(id, t) } }
  private func pruneBlobs() {
    session.pruneTabStates(keeping: Set(state.tabs.keys).union(state.archive.map(\.id)))
  }

  /// Engine tabs mirror the model: create for new/restored tabs, REBUILD when the tab's profile changed, sleep + drop for tabs that left it.
  private func reconcile() {
    for (id, rec) in state.tabs {
      let profile = state.space(rec.space)?.profile ?? state.spaces.first?.profile ?? ProfileID()
      if let existing = tabs[id] {
        guard tabProfile[id] != profile else { continue }
        // profile changed (moveTab across profiles): the live view still holds the OLD data store -> rebuild under the new one
        let wasLive = existing.isLive
        syncOne(id, existing); persistState(id, existing); existing.hibernate(force: true); lifecycle.unregister(id); tabs[id] = nil
        _ = wasLive
      }
      let blob = session.tabStateResult(id)
      if blob.failed { unreadBlobs.insert(id) } else { unreadBlobs.remove(id) }
      let t = factory.makeTab(id: id, url: URL(string: rec.url), profile: profile, restoredState: blob.data)
      tabs[id] = t; tabProfile[id] = profile
      t.onChange = { [weak self] in self?.tabChanged(id) }
      lifecycle.register(t, host: URL(string: rec.url)?.host, lastActive: rec.lastActive)
    }
    for id in Array(tabs.keys) where state.tabs[id] == nil {
      if let t = tabs[id] { persistState(id, t); t.hibernate(force: true) }
      lifecycle.unregister(id); tabs[id] = nil; tabProfile[id] = nil
    }
  }
}
