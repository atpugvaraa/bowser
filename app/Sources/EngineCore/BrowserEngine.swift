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
  var closeRequestHandler: ((TabID) -> Void)? { get set }
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
  private var visitedURL: [TabID: String] = [:]      // last URL recorded in history per tab (one visit per navigation)

  public init(session: SessionManager, state: BrowserState, factory: TabFactory, lifecycle: LifecycleManager = LifecycleManager()) {
    self.session = session; self.state = state; self.factory = factory; self.lifecycle = lifecycle
    factory.linkOpenHandler = { [weak self] from, url in self?.openLink(from: from, url: url) }
    factory.closeRequestHandler = { [weak self] id in self?.closeTab(id) }
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
    try? EngineSettings.saveUsage(lifecycle.usage, to: session)             // learned habits first: they survive even if the model save fails
    syncFromTabs()
    for (id, t) in tabs { persistState(id, t) }
    try session.save(state)
    _ = try? session.rotateBackup()
  }

  // MARK: settings
  public var policy: PolicyConfig { lifecycle.config }
  /// Apply and persist the user's hibernation settings (validated: a typo can never hibernate everything).
  public func updatePolicy(_ cfg: PolicyConfig) throws {
    let v = cfg.validated()
    try EngineSettings.savePolicy(v, to: session)         // persist first: the in-memory policy only changes if the save succeeded
    lifecycle.config = v
  }

  /// Never-sleep toggle for a tab's site. If the list already COVERS the host (exact entry or a parent domain such as example.com for
  /// app.example.com) the covering entry is removed; otherwise the host is added. Returns the new state (true = never sleeps).
  /// Throws on a save failure; an invalid host is a no-op that returns the current state.
  @discardableResult public func toggleNeverSleep(host: String) throws -> Bool {
    var c = lifecycle.config; let h = PolicyConfig.normalizeHost(host)
    guard !h.isEmpty else { return c.isNeverSleep(host: host) }
    let nowOn: Bool
    if let entry = c.neverSleepEntry(covering: h), let i = c.neverSleepHosts.firstIndex(of: entry) { c.neverSleepHosts.remove(at: i); nowOn = false }
    else { c.neverSleepHosts.append(h); nowOn = true }
    try updatePolicy(c); return nowOn
  }
  /// The list entry that protects `host`, for menu labels ("Allow example.com to Sleep").
  public func neverSleepEntry(covering host: String) -> String? { lifecycle.config.neverSleepEntry(covering: host) }

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
    syncOne(id, t); recordHistory(id, t); session.scheduleSave(state); onChange?()
  }
  /// One history visit per finished navigation to an http(s) page; later title updates refine it. Error pages and blank tabs are not history.
  private func recordHistory(_ id: TabID, _ t: any EngineTab) {
    guard !t.isLoadingPage, let u = t.currentURL, let sc = u.scheme?.lowercased(), sc == "http" || sc == "https", let rec = state.tabs[id], let profile = state.space(rec.space)?.profile else { return }
    let key = u.absoluteString
    if visitedURL[id] != key { visitedURL[id] = key; session.recordVisit(profile: profile, url: key, title: t.currentTitle ?? "") }
    else if let title = t.currentTitle { session.noteTitle(profile: profile, url: key, title: title) }
  }

  // MARK: quick open, bookmarks
  /// Everything the ⌘K palette can open, ranked: open tabs (all spaces), bookmarks, closed tabs, history.
  public func quickSearch(_ query: String, limit: Int = 30) -> [QuickCandidate] {
    var pool: [QuickCandidate] = []
    let now = Date()
    func recency(_ d: Date) -> Double { exp(-max(now.timeIntervalSince(d), 0) / (7 * 86_400)) }
    for sp in state.spaces { for tid in sp.tabOrder { if let r = state.tabs[tid] { pool.append(QuickCandidate(kind: .openTab, title: r.title, url: r.url, recency: recency(r.lastActive), tab: tid)) } } }
    for a in state.archive { pool.append(QuickCandidate(kind: .closedTab, title: a.title, url: a.url, recency: recency(a.closedAt), tab: a.id)) }
    for b in session.bookmarks() { pool.append(QuickCandidate(kind: .bookmark, title: b.title, url: b.url, recency: recency(b.added))) }
    for h in session.searchHistory(query: QuickSearch.words(query).first ?? "", limit: 200) { pool.append(QuickCandidate(kind: .history, title: h.title, url: h.url, recency: recency(h.lastVisited))) }
    return QuickSearch.rank(pool, query: query, limit: limit)
  }
  /// Open a palette result in `window`: switch to an open tab (its space too), restore a closed tab, or open a URL in a new tab.
  @discardableResult public func openQuickResult(_ c: QuickCandidate, in window: WindowID) -> SelectResult? {
    switch c.kind {
    case .openTab:
      guard let tid = c.tab, let rec = state.tabs[tid] else { return nil }
      if state.windows[window]?.space != rec.space { switchSpace(window: window, to: rec.space) }
      return select(tab: tid, in: window)
    case .closedTab:
      guard let tid = c.tab, case .restored(let nid) = restoreTab(tid) else { return nil }
      return select(tab: nid, in: window)
    case .bookmark, .history:
      guard let sp = state.windows[window]?.space, let id = newTab(in: sp, url: c.url, title: c.title, window: window) else { return nil }
      _ = id; return .selected
    }
  }
  /// Bookmark / un-bookmark the page shown in a tab (per profile). Returns true if it is bookmarked afterwards.
  @discardableResult public func toggleBookmark(tab id: TabID) throws -> Bool {
    guard let rec = state.tabs[id], let profile = state.space(rec.space)?.profile, let u = URL(string: rec.url), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" else { return false }
    if let existing = session.bookmarks(profile: profile).first(where: { $0.url == rec.url }) { try session.removeBookmark(existing.id); return false }
    try session.addBookmark(profile: profile, url: rec.url, title: rec.title.isEmpty ? (u.host ?? rec.url) : rec.title); return true
  }
  public func isBookmarked(tab id: TabID) -> Bool {
    guard let rec = state.tabs[id], let profile = state.space(rec.space)?.profile else { return false }
    return session.bookmarks(profile: profile).contains { $0.url == rec.url }
  }
  public func bookmarks(inSpace space: SpaceID) -> [Store.Bookmark] { state.space(space).map { session.bookmarks(profile: $0.profile) } ?? [] }
  public func clearHistory() throws { try session.clearHistory() }

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
