import AppKit
import BrowserCore
import EngineCore
import EngineWebKit
import Foundation
import Lifecycle
import Persistence
import Resources

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var engine: BrowserEngine!
  var session: SessionManager!
  var factory: WebKitTabFactory!
  var controllers: [WindowID: BrowserWindowController] = [:]
  private var pressure: PressureMonitor?
  private(set) var recovery: SessionManager.Recovery = .clean
  private(set) var dataDirForTests: URL = URL(fileURLWithPath: "/")
  let selfTestBase: String? = { let a = CommandLine.arguments; if let i = a.firstIndex(of: "--selftest"), i + 1 < a.count { return a[i + 1] }; return nil }()
  var isSelfTest: Bool { selfTestBase != nil }

  func applicationDidFinishLaunching(_ n: Notification) {
    do { try buildStack() } catch {
      let a = NSAlert(); a.messageText = "Can't open your session"; a.informativeText = "\(error)\n\nNothing was changed or deleted."; a.runModal(); NSApp.terminate(nil); return
    }
    NSApp.mainMenu = MainMenu.build(target: self)
    bootstrapIfEmpty()
    syncWindows()
    startServices()
    if case .clean = recovery {} else { announceRecovery() }
    if let base = selfTestBase { Task { @MainActor in await SelfTest(app: self, base: base).run() } }
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: stack
  func buildStack(dataDir: URL? = nil) throws {
    let dir = dataDir ?? (isSelfTest
      ? FileManager.default.temporaryDirectory.appendingPathComponent("browser-selftest-\(UUID().uuidString)")
      : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Browser"))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    dataDirForTests = dir
    let (s, state, rec) = try SessionManager.start(path: dir.appendingPathComponent("session.sqlite").path)
    session = s; recovery = rec
    factory = WebKitTabFactory(persistent: !isSelfTest)
    factory.externalOpenHandler = { NSWorkspace.shared.open($0) }
    let life = LifecycleManager(config: .relaxed, pressure: { [weak self] in self?.pressure?.level ?? .normal })
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
    _ = engine.newTab(in: sp, url: "https://duckduckgo.com", window: w)
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
  var keyController: BrowserWindowController? { controller(for: NSApp.keyWindow) ?? controllers.values.first }

  func downloadsChanged() {
    if factory.downloads.items.values.contains(where: { if case .finished = $0.state { return true }; return false }) { NSApp.requestUserAttention(.informationalRequest) }
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

  // MARK: menu actions (targets are nil-targeted or this delegate)
  @objc func newTab(_ s: Any?) { keyController?.newTab() }
  @objc func closeTab(_ s: Any?) { keyController?.closeSelectedTab() }
  @objc func reopenClosedTab(_ s: Any?) { keyController?.reopenClosedTab() }
  @objc func newWindow(_ s: Any?) { keyController?.newWindow() }
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
  @objc func showDownloads(_ s: Any?) { NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) }
  @objc func showResources(_ s: Any?) { keyController?.showResourceSummary() }

  // MARK: quit
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    engine.stopMaintenance()
    do { try engine.shutdown() } catch {
      let a = NSAlert(); a.alertStyle = .critical; a.messageText = "Couldn't save your session"
      a.informativeText = "\(error)\n\nQuitting now may lose your latest tab changes."
      a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Quit Anyway")
      if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
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
