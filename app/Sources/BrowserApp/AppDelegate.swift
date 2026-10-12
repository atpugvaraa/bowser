import AppKit
import BrowserCore
import ContentBlocking
import EngineCore
import EngineWebKit
import Foundation
import Lifecycle
import Persistence
import Resources

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
  var engine: BrowserEngine!
  var session: SessionManager!
  var factory: WebKitTabFactory!
  var controllers: [WindowID: BrowserWindowController] = [:]
  private var recentWindows: [WindowID] = []       // most recently key/shown first
  private var finishedDownloads = 0
  private var settings: SettingsWindowController?
  private var quickOpenStorage: QuickOpenController?
  var quickOpen: QuickOpenController { if quickOpenStorage == nil { quickOpenStorage = QuickOpenController() }; return quickOpenStorage! }
  private(set) var blocking = BlockingSettings()
  private var pressure: PressureMonitor?
  private(set) var recovery: SessionManager.Recovery = .clean
  private(set) var dataDirForTests: URL = URL(fileURLWithPath: "/")
  let selfTestBase: String? = { let a = CommandLine.arguments; if let i = a.firstIndex(of: "--selftest"), i + 1 < a.count { return a[i + 1] }; return nil }()
  var isSelfTest: Bool { selfTestBase != nil }

  func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.mainMenu = MainMenu.build(target: self)
    Task { @MainActor in await launch() }
  }

  /// Order matters: session -> content-blocking rules compiled -> engine (creates web views) -> windows.
  private func launch() async {
    do { try await buildStack() } catch {
      let a = NSAlert(); a.messageText = "Can't open your session"; a.informativeText = "\(error)\n\nNothing was changed or deleted."; a.runModal(); NSApp.terminate(nil); return
    }
    bootstrapIfEmpty()
    syncWindows()
    startServices()
    if !isSelfTest { if case .clean = recovery {} else { announceRecovery() } }
    if let base = selfTestBase { await SelfTest(app: self, base: base).run() } else { NSApp.activate(ignoringOtherApps: true) }
  }

  // MARK: stack
  func buildStack(dataDir: URL? = nil) async throws {
    let dir = dataDir ?? (isSelfTest
      ? FileManager.default.temporaryDirectory.appendingPathComponent("browser-selftest-\(UUID().uuidString)")
      : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Browser"))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(dir.path, 0o700)                         // also tighten a directory that already existed
    dataDirForTests = dir
    let (s, state, rec) = try SessionManager.start(path: dir.appendingPathComponent("session.sqlite").path)
    session = s; recovery = rec
    factory = WebKitTabFactory(persistent: !isSelfTest)
    factory.externalOpenHandler = { NSWorkspace.shared.open($0) }
    blocking = EngineSettings.loadBlocking(from: session)
    do { try await factory.prepareContentBlocking(blocking, storeURL: dir.appendingPathComponent("rulelists")) }
    catch { blocking.enabled = false; NSLog("content blocking unavailable: \(error)") }       // never block launch because of a list problem
    let life = LifecycleManager(config: EngineSettings.loadPolicy(from: session), usage: EngineSettings.loadUsage(from: session), pressure: { [weak self] in self?.pressure?.level ?? .normal })
    engine = BrowserEngine(session: session, state: state, factory: factory, lifecycle: life)
    engine.onChange = { [weak self] in self?.syncWindows() }
    factory.downloads.onChange = { [weak self] in self?.downloadsChanged() }
  }

  private func startServices() {
    engine.startMaintenance(every: 30)
    pressure = PressureMonitor { [weak self] _ in Task { @MainActor in _ = await self?.engine.maintenance() } }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.engine.noteWake() }
    }
  }

  /// First launch: one profile, one space, one window, one tab.
  func bootstrapIfEmpty() {
    guard engine.state.spaces.isEmpty else {
      if engine.state.windows.isEmpty, let sp = engine.state.spaces.first { _ = engine.openWindow(space: sp.id) }
      return
    }
    let sp = engine.addSpace(name: "Main", profile: ProfileID())
    let w = engine.openWindow(space: sp)!
    _ = engine.newTab(in: sp, url: isSelfTest ? "about:blank" : "https://duckduckgo.com", window: w)
  }

  // MARK: windows
  func syncWindows() {
    for id in engine.state.windows.keys where controllers[id] == nil {
      let c = BrowserWindowController(id: id, app: self); controllers[id] = c; c.show()
    }
    for (id, c) in controllers where engine.state.windows[id] == nil { controllers[id] = nil; c.closeFromEngine() }
    controllers.values.forEach { $0.refresh() }
  }
  func controller(for window: NSWindow?) -> BrowserWindowController? { controllers.values.first { $0.window === window } }
  /// The window an action applies to: key window, else main window, else the last one that was key (never an arbitrary one).
  var keyController: BrowserWindowController? {
    controller(for: NSApp.keyWindow) ?? controller(for: NSApp.mainWindow) ?? recentWindows.lazy.compactMap { self.controllers[$0] }.first ?? controllers.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }.first
  }
  func noteKey(_ id: WindowID) { recentWindows.removeAll { $0 == id }; recentWindows.insert(id, at: 0); if recentWindows.count > 32 { recentWindows.removeLast() } }

  func downloadsChanged() {
    let done = factory.downloads.items.values.filter { if case .finished = $0.state { return true }; return false }.count
    if done > finishedDownloads { NSApp.requestUserAttention(.informationalRequest) }          // only for NEWLY finished downloads
    finishedDownloads = done
  }

  private func announceRecovery() {
    let a = NSAlert(); a.alertStyle = .warning
    switch recovery {
    case .restoredFromBackup(_, let age):
      a.messageText = "Your session was restored from a backup"
      a.informativeText = "The session database was damaged. Tabs from about \(Int(age / 60)) minutes ago were recovered; the damaged file was kept next to it."
    case .quarantined(let path):
      a.messageText = "Your session could not be recovered"
      a.informativeText = "A copy of the damaged session was kept at:\n\(path)\nStarting fresh."
    case .clean: return
    }
    a.runModal()
  }

  /// Apply + persist content-blocking settings. Affects page loads from now on (reload a page to see the change).
  func applyBlocking(_ b: BlockingSettings) async throws {
    try EngineSettings.saveBlocking(b, to: session)
    try await factory.prepareContentBlocking(b, storeURL: dataDirForTests.appendingPathComponent("rulelists"))
    blocking = b
  }

  // MARK: menu actions (targets are nil-targeted or this delegate)
  @objc func newTab(_ s: Any?) {
    if let c = keyController { c.newTab() }
    else if let sp = engine.state.spaces.first, let w = engine.openWindow(space: sp.id) { _ = engine.newTab(in: sp.id, url: "about:blank", window: w); controllers[w]?.focusAddress() }   // no window open: make one
  }
  @objc func closeTab(_ s: Any?) { keyController?.closeSelectedTab() }
  @objc func reopenClosedTab(_ s: Any?) { keyController?.reopenClosedTab() }
  @objc func newWindow(_ s: Any?) { if let c = keyController { c.newWindow() } else if let sp = engine.state.spaces.first { _ = engine.openWindow(space: sp.id) } }
  @objc func closeWindow(_ s: Any?) { NSApp.keyWindow?.performClose(nil) }
  @objc func focusAddress(_ s: Any?) { keyController?.focusAddress() }
  @objc func reloadPage(_ s: Any?) { keyController?.reload() }
  @objc func stopPage(_ s: Any?) { keyController?.stop() }
  @objc func goBack(_ s: Any?) { keyController?.back() }
  @objc func goForward(_ s: Any?) { keyController?.forward() }
  @objc func nextTab(_ s: Any?) { keyController?.selectAdjacent(+1) }
  @objc func previousTab(_ s: Any?) { keyController?.selectAdjacent(-1) }
  @objc func selectTabNumber(_ s: NSMenuItem) { keyController?.selectTab(number: s.tag) }
  @objc func newSpace(_ s: Any?) { keyController?.newSpacePrompt() }
  @objc func switchSpace(_ s: NSMenuItem) { keyController?.switchSpace(index: s.tag) }
  @objc func sleepOtherTabs(_ s: Any?) { keyController?.sleepOthers() }
  @objc func quickOpenCommand(_ s: Any?) { keyController?.showQuickOpen() }
  @objc func bookmarkPage(_ s: Any?) { keyController?.toggleBookmark() }
  @objc func openBookmarkItem(_ s: NSMenuItem) { if let u = s.representedObject as? String { keyController?.openBookmark(u) } }
  @objc func zoomIn(_ s: Any?) { keyController?.zoom(by: 1.1) }
  @objc func zoomOut(_ s: Any?) { keyController?.zoom(by: 1 / 1.1) }
  @objc func zoomReset(_ s: Any?) { keyController?.zoomReset() }
  @objc func printPage(_ s: Any?) { keyController?.printPage() }
  @objc func showSettings(_ s: Any?) { settingsController.show() }
  var settingsController: SettingsWindowController { if settings == nil { settings = SettingsWindowController(app: self) }; return settings! }
  @objc func showDownloads(_ s: Any?) { NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) }
  @objc func showResources(_ s: Any?) { keyController?.showResourceSummary() }

  // MARK: menus
  /// The Spaces menu lists the current spaces (⌃1…⌃9 switch).
  func menuNeedsUpdate(_ menu: NSMenu) {
    guard engine != nil else { return }
    if menu.title == "Bookmarks" {
      for it in menu.items where it.tag == 900 { menu.removeItem(it) }                 // only the dynamic list below the static item is rebuilt
      let list = keyController?.space.map { engine.bookmarks(inSpace: $0) } ?? []
      if list.isEmpty { let e = NSMenuItem(title: "No bookmarks yet", action: nil, keyEquivalent: ""); e.isEnabled = false; e.tag = 900; menu.addItem(e) }
      for b in list.prefix(60) { let i = NSMenuItem(title: b.title.isEmpty ? b.url : String(b.title.prefix(60)), action: #selector(openBookmarkItem(_:)), keyEquivalent: ""); i.target = self; i.representedObject = b.url; i.toolTip = b.url; i.tag = 900; menu.addItem(i) }
      return
    }
    guard menu.title == "Spaces" else { return }
    menu.removeAllItems()
    for (i, sp) in engine.state.spaces.enumerated() {
      let it = NSMenuItem(title: sp.name, action: #selector(switchSpace(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : ""); it.keyEquivalentModifierMask = .control
      it.tag = i; it.target = self; it.state = keyController?.space == sp.id ? .on : .off; menu.addItem(it)
    }
    menu.addItem(.separator()); let n = NSMenuItem(title: "New Space…", action: #selector(newSpace(_:)), keyEquivalent: ""); n.target = self; menu.addItem(n)
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard engine != nil else { return false }                       // still launching
    guard let c = keyController, let t = c.selected.flatMap({ engine.tab($0) }) else {
      return [#selector(newTab(_:)), #selector(newWindow(_:)), #selector(newSpace(_:)), #selector(showDownloads(_:)), #selector(closeWindow(_:))].contains(item.action!) || item.action == #selector(switchSpace(_:))
    }
    switch item.action {
    case #selector(goBack(_:)): return t.canGoBack
    case #selector(goForward(_:)): return t.canGoForward
    case #selector(stopPage(_:)): return t.isLoadingPage
    case #selector(reopenClosedTab(_:)): return !engine.state.archive.isEmpty
    default: return true
    }
  }

  // MARK: quit
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let engine else { return .terminateNow }                 // startup failed before the engine existed: nothing to save
    engine.stopMaintenance()
    do { try engine.shutdown() } catch {
      let a = NSAlert(); a.alertStyle = .critical; a.messageText = "Couldn't save your session"
      a.informativeText = "\(error)\n\nQuitting now may lose your latest tab changes."
      a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Quit Anyway")
      if a.runModal() == .alertFirstButtonReturn { engine.startMaintenance(every: 30); return .terminateCancel }       // keep hibernation/backups running
    }
    return .terminateNow
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if engine.state.windows.isEmpty, let sp = engine.state.spaces.first { _ = engine.openWindow(space: sp.id) }
    return true
  }
}

/// Self-test helper: reopen the session database a second time, like a relaunch.
@MainActor
enum SessionManagerBridge {
  static func reopen(dir: URL) throws -> (SessionManager, BrowserState, String) {
    let (m, s, r) = try SessionManager.start(path: dir.appendingPathComponent("session.sqlite").path)
    if case .clean = r { return (m, s, "clean") }
    return (m, s, "\(r)")
  }
}
