import AppKit
import BrowserCore
import EngineCore
import EngineWebKit
import Extensions
import WebKit

/// App side of the extension engine: the engine-environment adapter, install flow with an explicit permission prompt, the Extensions menu and popups.
@MainActor
final class ExtensionsUI: NSObject, ExtensionEnvironment, NSMenuDelegate {
  unowned let app: AppDelegate
  let host: ExtensionHost
  let root: URL
  private var known: Set<TabID> = []
  private var lastSelected: [WindowID: TabID] = [:]
  private var popover: NSPopover?

  init(app: AppDelegate, host: ExtensionHost, root: URL) {
    self.app = app; self.host = host; self.root = root; super.init()
    host.environment = self
    host.presentPopup = { [weak self] p in self?.show(p) }
  }
  private var engine: BrowserEngine { app.engine }

  // MARK: ExtensionEnvironment
  func windowIDs() -> [WindowID] { Array(engine.state.windows.keys) }
  func focusedWindow() -> WindowID? { app.keyController?.id }
  func tabs(in window: WindowID) -> [WebKitTab] {
    guard let w = engine.state.windows[window], let sp = engine.state.space(w.space) else { return [] }
    return sp.tabOrder.compactMap { engine.tab($0) as? WebKitTab }
  }
  func selectedTab(in window: WindowID) -> WebKitTab? { engine.state.windows[window]?.selected.flatMap { engine.tab($0) as? WebKitTab } }
  func window(of tab: TabID) -> WindowID? {
    guard let rec = engine.state.tabs[tab] else { return nil }
    return engine.state.windows.values.first { $0.selected == tab }?.id ?? engine.state.windows.values.first { $0.space == rec.space }?.id
  }
  func openTab(url: URL?, active: Bool, in window: WindowID?) -> WebKitTab? {
    guard let w = window ?? app.keyController?.id, let sp = engine.state.windows[w]?.space, let id = engine.newTab(in: sp, url: url?.absoluteString ?? "about:blank", window: active ? w : nil) else { return nil }
    return engine.tab(id) as? WebKitTab
  }
  func select(_ tab: TabID) { if let w = window(of: tab) { _ = engine.select(tab: tab, in: w) } }
  func close(_ tab: TabID) { engine.closeTab(tab) }

  private func profile(of tab: TabID) -> ProfileID? { engine.state.tabs[tab].flatMap { engine.state.space($0.space)?.profile } }

  /// Called after every engine change: tells the extensions about tabs that appeared, changed or went away.
  func sync() {
    let live = Set(engine.state.tabs.keys.filter { (engine.tab($0) as? WebKitTab)?.webView != nil })
    for id in live.subtracting(known) { if let t = engine.tab(id) as? WebKitTab, let p = profile(of: id) { host.didOpen(t, profile: p) } }
    for id in known.subtracting(live) { if let p = profile(of: id) { host.didClose(id, profile: p, windowClosing: false) } }
    known = live
    for (wid, w) in engine.state.windows {
      guard let sel = w.selected, lastSelected[wid] != sel, let t = engine.tab(sel) as? WebKitTab, let p = profile(of: sel) else { continue }
      host.didActivate(t, previous: lastSelected[wid].flatMap { engine.tab($0) as? WebKitTab }, profile: p); lastSelected[wid] = sel
    }
  }

  // MARK: install
  func installFlow() {
    let panel = NSOpenPanel(); panel.message = "Choose a Chrome or Firefox extension (.crx, .xpi, .zip) or an unpacked folder"
    panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    install(url)
  }
  func install(_ url: URL) {
    let root = self.root
    Task { @MainActor in
      let prepared: ExtensionPackage.Prepared
      do { prepared = try await Task.detached { try ExtensionPackage.prepare(source: url, into: root) }.value }
      catch { alert("Can't install this extension", "\(error)\n\nNothing was changed."); return }
      guard confirm(prepared) else { return }
      await host.install(prepared, permissions: prepared.permissions, hosts: prepared.hostPatterns)
      if let e = host.loadErrors[prepared.id] { alert("Installed with a problem", "\(prepared.name): \(e)") }
    }
  }
  private func confirm(_ p: ExtensionPackage.Prepared) -> Bool {
    var lines: [String] = []
    let broad = p.hostPatterns.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0 == "*://*/*" }
    if broad { lines.append("• Read and change data on ALL websites you visit") }
    else { lines += p.hostPatterns.prefix(8).map { "• Read and change data on \($0)" } }
    lines += p.permissions.map { "• " + Self.describe($0) }
    lines += p.notes.map { "ℹ︎ " + $0 }
    let a = NSAlert(); a.messageText = "Add “\(p.name)” \(p.version)?"
    a.informativeText = (p.isFirefox ? "Firefox extension. " : "Chrome extension. ") + "It will be able to:\n\n" + (lines.isEmpty ? "(no special access)" : lines.joined(separator: "\n"))
    a.addButton(withTitle: "Add Extension"); a.addButton(withTitle: "Cancel"); a.alertStyle = broad ? .warning : .informational
    return a.runModal() == .alertFirstButtonReturn
  }
  static func describe(_ perm: String) -> String {
    switch perm {
    case "tabs": return "See the address and title of your open tabs"
    case "storage": return "Store its own settings"
    case "cookies": return "Read and change cookies"
    case "history": return "Read your browsing history"
    case "bookmarks": return "Read and change your bookmarks"
    case "downloads": return "Manage downloads"
    case "webRequest", "webRequestBlocking", "declarativeNetRequest": return "Block or change network requests"
    case "nativeMessaging": return "Talk to apps installed on this Mac"
    case "clipboardRead": return "Read the clipboard"
    case "clipboardWrite": return "Write to the clipboard"
    case "notifications": return "Show notifications"
    case "scripting": return "Run scripts in pages it has access to"
    case "activeTab": return "Access the current tab when you click it"
    default: return "Use “\(perm)”"
    }
  }
  private func alert(_ title: String, _ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal() }

  // MARK: menu
  func showMenu(from view: NSView) {
    let m = NSMenu(); build(m)
    m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
  }
  func build(_ m: NSMenu) {
    m.removeAllItems()
    let i = NSMenuItem(title: "Install Extension…", action: #selector(installClicked), keyEquivalent: ""); i.target = self; m.addItem(i)
    if !host.records.isEmpty { m.addItem(.separator()) }
    for r in host.records {
      let sub = NSMenu()
      let open = NSMenuItem(title: "Open", action: #selector(openClicked(_:)), keyEquivalent: ""); open.target = self; open.representedObject = r.id; open.isEnabled = r.enabled; sub.addItem(open)
      let en = NSMenuItem(title: r.enabled ? "Turn Off" : "Turn On", action: #selector(toggleClicked(_:)), keyEquivalent: ""); en.target = self; en.representedObject = r.id; sub.addItem(en)
      let rm = NSMenuItem(title: "Remove…", action: #selector(removeClicked(_:)), keyEquivalent: ""); rm.target = self; rm.representedObject = r.id; sub.addItem(rm)
      if let e = host.loadErrors[r.id] { sub.addItem(.separator()); sub.addItem(withTitle: "Problem: \(e)", action: nil, keyEquivalent: "") }
      let item = NSMenuItem(title: "\(r.name) \(r.version)", action: nil, keyEquivalent: ""); item.submenu = sub; item.state = r.enabled ? .on : .off; m.addItem(item)
    }
  }
  func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }
  @objc private func installClicked() { installFlow() }
  @objc private func openClicked(_ s: NSMenuItem) {
    guard let id = s.representedObject as? String, let c = app.keyController, let sel = c.selected, let p = profile(of: sel) else { return }
    host.performAction(id, tab: engine.tab(sel) as? WebKitTab, profile: p)
  }
  @objc private func toggleClicked(_ s: NSMenuItem) { if let id = s.representedObject as? String, let r = host.records.first(where: { $0.id == id }) { Task { await host.setEnabled(id, !r.enabled) } } }
  @objc private func removeClicked(_ s: NSMenuItem) {
    guard let id = s.representedObject as? String, let r = host.records.first(where: { $0.id == id }) else { return }
    let a = NSAlert(); a.messageText = "Remove “\(r.name)”?"; a.informativeText = "It stops running everywhere. Its files stay on disk, so adding it again restores it."
    a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
    if a.runModal() == .alertFirstButtonReturn { host.uninstall(id) }
  }

  private func show(_ p: NSPopover) {
    guard let c = app.keyController, let v = c.window.contentView else { return }
    popover?.close(); popover = p
    p.show(relativeTo: NSRect(x: v.bounds.maxX - 60, y: v.bounds.maxY - 8, width: 1, height: 1), of: v, preferredEdge: .minY)
  }
}
