import AppKit
import BrowserCore
import EngineCore
import EngineWebKit
import Foundation
import WebKit

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
  let id: WindowID
  unowned let app: AppDelegate
  let window: NSWindow
  private let spacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let table = NSTableView()
  private let backButton = NSButton(), forwardButton = NSButton(), reloadButton = NSButton()
  let addressField = NSTextField()
  let extButton = NSButton()
  private let progress = NSProgressIndicator()
  private let content = NSView()
  private var rows: [TabID] = []
  private var shownTab: TabID?
  private var updatingSelection = false
  private var closingFromEngine = false
  private var engine: BrowserEngine { app.engine }

  var selected: TabID? { engine.state.windows[id]?.selected }
  var space: SpaceID? { engine.state.windows[id]?.space }
  var rowTitles: [String] { rows.map(title(for:)) }                    // for the self-test

  init(id: WindowID, app: AppDelegate) {
    self.id = id; self.app = app
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    window.delegate = self; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 700, height: 420)
    buildUI()
  }

  func show() {
    if let f = engine.state.windows[id]?.frame, f.count == 4, frameIsOnScreen(NSRect(x: f[0], y: f[1], width: f[2], height: f[3])) {
      window.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: false)            // where you left it
    } else { window.center(); let n = max(app.controllers.count - 1, 0); window.setFrameTopLeftPoint(NSPoint(x: 80 + 28 * n, y: 760 - 28 * n)) }
    app.noteKey(id)                                  // the newest window is the fallback action target when no window is key
    if app.isSelfTest { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }       // the unattended self-test must not steal focus
  }
  /// A saved frame is only used if a useful part of it is still on a connected screen (monitor unplugged, resolution changed...).
  private func frameIsOnScreen(_ r: NSRect) -> Bool {
    NSScreen.screens.contains { s in let i = s.visibleFrame.intersection(r); return i.width >= 200 && i.height >= 120 }
  }
  private func saveFrame() { let f = window.frame; engine.setWindowFrame(id, x: Double(f.origin.x), y: Double(f.origin.y), width: Double(f.width), height: Double(f.height)) }
  func windowDidMove(_ n: Notification) { NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveFrameDebounced), object: nil); perform(#selector(saveFrameDebounced), with: nil, afterDelay: 0.5) }
  func windowDidResize(_ n: Notification) { windowDidMove(n) }
  @objc private func saveFrameDebounced() { if !closingFromEngine { saveFrame() } }
  func closeFromEngine() { if !closingFromEngine { closingFromEngine = true; window.close() } }

  // MARK: UI construction
  private func buildUI() {
    let root = NSView(); window.contentView = root

    let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.translatesAutoresizingMaskIntoConstraints = false
    spacePopup.target = self; spacePopup.action = #selector(spaceChanged(_:)); spacePopup.translatesAutoresizingMaskIntoConstraints = false
    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab")); col.resizingMask = .autoresizingMask; table.addTableColumn(col)
    table.headerView = nil; table.rowHeight = 30; table.style = .sourceList; table.dataSource = self; table.delegate = self
    table.allowsEmptySelection = true; table.allowsMultipleSelection = false; table.backgroundColor = .clear
    let menu = NSMenu(); menu.delegate = self; table.menu = menu
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
    let newTabButton = NSButton(title: "New Tab", target: self, action: #selector(newTabClicked)); newTabButton.bezelStyle = .rounded
    newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab"); newTabButton.imagePosition = .imageLeading; newTabButton.translatesAutoresizingMaskIntoConstraints = false
    sidebar.addSubview(spacePopup); sidebar.addSubview(scroll); sidebar.addSubview(newTabButton)

    func style(_ b: NSButton, _ symbol: String, _ action: Selector, _ tip: String) {
      b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip); b.bezelStyle = .texturedRounded; b.isBordered = true
      b.target = self; b.action = action; b.toolTip = tip; b.translatesAutoresizingMaskIntoConstraints = false
    }
    style(backButton, "chevron.left", #selector(backClicked), "Back"); style(forwardButton, "chevron.right", #selector(forwardClicked), "Forward"); style(reloadButton, "arrow.clockwise", #selector(reloadClicked), "Reload")
    addressField.placeholderString = "Search or enter website"; addressField.bezelStyle = .roundedBezel; addressField.delegate = self
    addressField.lineBreakMode = .byTruncatingTail; addressField.translatesAutoresizingMaskIntoConstraints = false
    progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.controlSize = .small; progress.isHidden = true; progress.translatesAutoresizingMaskIntoConstraints = false
    let bar = NSView(); bar.translatesAutoresizingMaskIntoConstraints = false
    style(extButton, "puzzlepiece.extension", #selector(extensionsClicked), "Extensions")
    [backButton, forwardButton, reloadButton, addressField, extButton].forEach { bar.addSubview($0) }
    content.translatesAutoresizingMaskIntoConstraints = false; content.wantsLayer = true
    let main = NSView(); main.translatesAutoresizingMaskIntoConstraints = false
    [bar, progress, content].forEach { main.addSubview($0) }
    let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.translatesAutoresizingMaskIntoConstraints = false
    split.addArrangedSubview(sidebar); split.addArrangedSubview(main)
    root.addSubview(split)
    NSLayoutConstraint.activate([
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180), sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      spacePopup.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 38), spacePopup.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10), spacePopup.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
      scroll.topAnchor.constraint(equalTo: spacePopup.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: newTabButton.topAnchor, constant: -8),
      newTabButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10), newTabButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10), newTabButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
      bar.topAnchor.constraint(equalTo: main.topAnchor), bar.leadingAnchor.constraint(equalTo: main.leadingAnchor), bar.trailingAnchor.constraint(equalTo: main.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 40),
      backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4), forwardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4), reloadButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      addressField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 10), addressField.trailingAnchor.constraint(equalTo: extButton.leadingAnchor, constant: -8), extButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10), extButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor), addressField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      progress.topAnchor.constraint(equalTo: bar.bottomAnchor), progress.leadingAnchor.constraint(equalTo: main.leadingAnchor), progress.trailingAnchor.constraint(equalTo: main.trailingAnchor), progress.heightAnchor.constraint(equalToConstant: 3),
      content.topAnchor.constraint(equalTo: progress.bottomAnchor), content.leadingAnchor.constraint(equalTo: main.leadingAnchor), content.trailingAnchor.constraint(equalTo: main.trailingAnchor), content.bottomAnchor.constraint(equalTo: main.bottomAnchor),
    ])
    split.setPosition(250, ofDividerAt: 0)
  }

  // MARK: state -> UI
  func title(for id: TabID) -> String {
    guard let r = engine.state.tabs[id] else { return "" }
    if !r.title.isEmpty { return r.title }
    if r.url == "about:blank" { return "New Tab" }
    return URL(string: r.url)?.host ?? r.url
  }

  private var spaceSignature = "", rowSignature = ""
  func refresh() {
    guard let w = engine.state.windows[id], let sp = engine.state.space(w.space) else { return }
    // Rebuild the popup / table only when their content changed: an open popup or context menu must not be rebuilt under the user.
    let sSig = engine.state.spaces.map { "\($0.id.raw)\($0.name)" }.joined() + "|\(sp.id.raw)"
    if sSig != spaceSignature {
      spaceSignature = sSig; spacePopup.removeAllItems()
      for (i, s) in engine.state.spaces.enumerated() { spacePopup.addItem(withTitle: s.name); spacePopup.lastItem?.tag = i }
      if let i = engine.state.spaces.firstIndex(where: { $0.id == sp.id }) { spacePopup.selectItem(at: i) }
    }
    rows = sp.tabOrder
    let rSig = rows.map { "\($0.raw)|\(title(for: $0))|\(engine.tab($0)?.isLive ?? false)" }.joined(separator: "\n") + "#\(w.selected?.raw.uuidString ?? "")"
    if rSig != rowSignature {
      rowSignature = rSig; updatingSelection = true
      table.reloadData()
      if let s = w.selected, let r = rows.firstIndex(of: s) { table.selectRowIndexes([r], byExtendingSelection: false) } else { table.deselectAll(nil) }
      updatingSelection = false
    }
    attachSelected()
    let t = w.selected.flatMap { engine.tab($0) }
    window.title = w.selected.map(title(for:)) ?? "Browser"
    window.subtitle = sp.name
    if !isEditingAddress { addressField.stringValue = displayURL(w.selected) }
    backButton.isEnabled = t?.canGoBack ?? false; forwardButton.isEnabled = t?.canGoForward ?? false
    let loading = t?.isLoadingPage ?? false
    reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
    reloadButton.toolTip = loading ? "Stop" : "Reload"
    progress.isHidden = !loading; progress.doubleValue = t?.progress ?? 0
  }

  private func displayURL(_ id: TabID?) -> String {
    guard let id, let r = engine.state.tabs[id] else { return "" }
    let live = engine.tab(id)?.currentURL?.absoluteString ?? r.url
    return live == "about:blank" ? "" : live
  }
  private var isEditingAddress: Bool { window.firstResponder === addressField.currentEditor() && addressField.currentEditor() != nil }

  /// Show the selected tab's web view in the content area (the engine keeps visible tabs live).
  private func attachSelected() {
    guard let sel = selected else { for v in content.subviews { v.removeFromSuperview() }; shownTab = nil; return }
    guard let wk = engine.tab(sel) as? WebKitTab else { return }
    let view = wk.ensureLive()
    if shownTab == sel && view.superview === content { return }
    for v in content.subviews { v.removeFromSuperview() }
    view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
    NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor), view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    shownTab = sel
    if !isEditingAddress { window.makeFirstResponder(view) }
  }

  // MARK: table
  func numberOfRows(in t: NSTableView) -> Int { rows.count }
  func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    guard row < rows.count else { return nil }
    let id = rows[row]; let cell = NSTableCellView()
    let live = engine.tab(id)?.isLive ?? false
    let dot = NSImageView(image: NSImage(systemSymbolName: live ? "circle.fill" : "moon.zzz", accessibilityDescription: live ? "awake" : "sleeping") ?? NSImage())
    dot.contentTintColor = live ? .systemGreen : .tertiaryLabelColor; dot.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(labelWithString: title(for: id)); label.lineBreakMode = .byTruncatingTail; label.textColor = live ? .labelColor : .secondaryLabelColor; label.translatesAutoresizingMaskIntoConstraints = false
    let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") ?? NSImage(), target: self, action: #selector(closeRowClicked(_:)))
    close.isBordered = false; close.tag = row; close.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(dot); cell.addSubview(label); cell.addSubview(close)
    NSLayoutConstraint.activate([
      dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor), dot.widthAnchor.constraint(equalToConstant: 12),
      label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
      close.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), close.centerYAnchor.constraint(equalTo: cell.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 16),
    ])
    return cell
  }
  func tableViewSelectionDidChange(_ n: Notification) {
    guard !updatingSelection, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
    selectTab(rows[table.selectedRow])
  }
  @objc private func closeRowClicked(_ b: NSButton) { if b.tag < rows.count { closeTab(rows[b.tag]) } }

  func selectTab(_ tab: TabID) {
    switch engine.select(tab: tab, in: id) {
    case .focusWindow(let other): app.controllers[other]?.window.makeKeyAndOrderFront(nil); refresh()      // a tab can only be shown in one window
    default: break
    }
  }

  // MARK: actions
  @objc func newTabClicked() { newTab() }
  func newTab() {
    guard let sp = space, let t = engine.newTab(in: sp, url: "about:blank", window: id) else { return }
    _ = t; focusAddress()
  }
  func closeSelectedTab() { if let s = selected { closeTab(s) } }
  func closeTab(_ t: TabID) {
    let sp = space; engine.closeTab(t)
    if let sp, engine.state.space(sp)?.tabOrder.isEmpty == true { newTab() }       // a window never ends up with nothing to show
  }
  func reopenClosedTab() {
    switch engine.reopenLastClosed() {
    case .restored(let t): selectTab(t)
    case .needsProfileConfirmation:
      let al = NSAlert(); al.alertStyle = .warning; al.messageText = "Reopen in a different profile?"
      al.informativeText = "The space this tab was closed in no longer exists. Reopening it here signs it in as a different profile (separate logins and cookies)."
      al.addButton(withTitle: "Reopen"); al.addButton(withTitle: "Cancel")
      if al.runModal() == .alertFirstButtonReturn, case .restored(let t) = engine.reopenLastClosed(confirmedCrossProfile: true) { selectTab(t) }
    case .notFound: NSSound.beep()
    }
  }
  func newWindow() { if let sp = space { _ = engine.openWindow(space: sp) } }
  func focusAddress() { window.makeFirstResponder(addressField); addressField.selectText(nil) }
  func reload() { if let s = selected { (engine.tab(s))?.reload() } }
  func stop() { if let s = selected { (engine.tab(s))?.stopLoading() } }
  func back() { if let s = selected { (engine.tab(s))?.goBack() } }
  func forward() { if let s = selected { (engine.tab(s))?.goForward() } }
  @objc private func extensionsClicked() { app.extensions?.showMenu(from: extButton) }
  @objc private func backClicked() { back() }
  @objc private func forwardClicked() { forward() }
  @objc private func reloadClicked() { if selected.flatMap({ engine.tab($0)?.isLoadingPage }) == true { stop() } else { reload() } }
  func selectAdjacent(_ d: Int) {
    guard let s = selected, let i = rows.firstIndex(of: s), !rows.isEmpty else { return }
    selectTab(rows[(i + d + rows.count) % rows.count])
  }
  func selectTab(number n: Int) { if n >= 1, n <= rows.count { selectTab(rows[n == 9 ? rows.count - 1 : n - 1]) } }

  // spaces
  @objc private func spaceChanged(_ p: NSPopUpButton) { switchSpace(index: p.indexOfSelectedItem) }
  func switchSpace(index: Int) {
    guard index >= 0, index < engine.state.spaces.count else { return }
    engine.switchSpace(window: id, to: engine.state.spaces[index].id)
  }
  func newSpacePrompt() {
    let a = NSAlert(); a.messageText = "New Space"; a.informativeText = "A space groups tabs. A separate profile keeps its own logins and cookies."
    let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); name.placeholderString = "Name"
    let sep = NSButton(checkboxWithTitle: "Separate profile (own logins and cookies)", target: nil, action: nil)
    let stack = NSStackView(views: [name, sep]); stack.orientation = .vertical; stack.alignment = .leading; stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
    a.accessoryView = stack; a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn, !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    createSpace(name: name.stringValue, separateProfile: sep.state == .on)
  }
  @discardableResult func createSpace(name: String, separateProfile: Bool) -> SpaceID? {
    guard let cur = space.flatMap({ engine.state.space($0) }) else { return nil }
    let sp = engine.addSpace(name: name, profile: separateProfile ? ProfileID() : cur.profile)
    engine.switchSpace(window: id, to: sp)
    newTab(); return sp
  }

  private var selectedWebView: WKWebView? { selected.flatMap { (engine.tab($0) as? WebKitTab)?.webView } }
  func zoom(by f: Double) { if let w = selectedWebView { w.pageZoom = min(max(w.pageZoom * f, 0.25), 5) } }
  func zoomReset() { selectedWebView?.pageZoom = 1 }
  var currentZoom: Double { Double(selectedWebView?.pageZoom ?? 1) }
  func printPage() {
    guard let w = selectedWebView else { return }
    let op = w.printOperation(with: NSPrintInfo.shared); op.view?.frame = w.bounds
    op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
  }

  func showQuickOpen() { app.quickOpen.show(for: self) }
  func toggleBookmark() {
    guard let s = selected else { return }
    if (try? engine.toggleBookmark(tab: s)) == nil { NSSound.beep() }
  }
  func openBookmark(_ url: String) { if let sp = space { _ = engine.newTab(in: sp, url: url, window: id) } }

  func sleepOthers() {
    guard let sp = space.flatMap({ engine.state.space($0) }) else { return }
    for t in sp.tabOrder where t != selected { Task { @MainActor in _ = await engine.lifecycle.sleepNow(t); refresh() } }
  }

  func showResourceSummary() {
    var lines: [(String, UInt64)] = []; var live = 0; var total: UInt64 = 0; var seen = Set<pid_t>()
    for (tid, _) in engine.state.tabs { if let wk = engine.tab(tid) as? WebKitTab, wk.isLive { live += 1; if let p = wk.processID, seen.insert(p).inserted, let m = wk.memoryFootprint { total += m; lines.append((title(for: tid), m)) } } }
    let a = NSAlert(); a.messageText = "Memory & Tabs"
    let top = lines.sorted { $0.1 > $1.1 }.prefix(8).map { "\(Int($0.1 / 1_048_576)) MB  \($0.0)" }.joined(separator: "\n")
    a.informativeText = "\(live) of \(engine.state.tabs.count) tabs awake · web content \(Int(total / 1_048_576)) MB · \(engine.state.archive.count) closed (recoverable)\n\n\(top)"
    a.runModal()
  }

  // MARK: address bar
  func submitAddress() {
    guard let s = selected else { return }
    if engine.navigate(tab: s, input: addressField.stringValue) {
      addressField.textColor = .labelColor; window.makeFirstResponder(engine.tab(s).flatMap { ($0 as? WebKitTab)?.webView })
    } else {                                                        // refused (javascript:, file:, ...): visible, not just a beep
      addressField.textColor = .systemRed; addressField.toolTip = "This kind of address can't be opened from the address bar."; NSSound.beep()
    }
  }
  private var preconnectWork: DispatchWorkItem?
  private var lastPreconnect = ""
  func controlTextDidChange(_ n: Notification) {
    addressField.textColor = .labelColor; addressField.toolTip = nil
    // Open the connection to the page being typed while the user is still typing (measured: first byte 220 -> 120 ms on GitHub, 220 -> 40 ms on BBC).
    // Only after typing pauses, and only for something that already looks like a complete host (a dot and a 2+ letter ending), so half-typed names are never looked up.
    preconnectWork?.cancel()
    let text = addressField.stringValue
    let work = DispatchWorkItem { [weak self] in
      guard let self, let url = URLInput.resolve(text), let host = url.host?.lowercased(), url.scheme == "https",
            let last = host.split(separator: ".").last, host.contains("."), last.count >= 2, last.allSatisfy(\.isLetter), host != self.lastPreconnect else { return }
      self.lastPreconnect = host
      SpeedTuning.preconnect(url, using: self.selectedWebView)
    }
    preconnectWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }
  /// Leaving the field without pressing Return must not leave typed text that looks like the page's address (spoofing).
  func controlTextDidEndEditing(_ n: Notification) {
    if (n.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement { return }
    addressField.stringValue = displayURL(selected); addressField.textColor = .labelColor
  }
  func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.insertNewline(_:)) { submitAddress(); return true }
    if sel == #selector(NSResponder.cancelOperation(_:)) { addressField.stringValue = displayURL(selected); window.makeFirstResponder(nil); return true }
    return false
  }

  // MARK: context menu
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let row = table.clickedRow; guard row >= 0, row < rows.count else { return }
    let tid = rows[row]
    func item(_ t: String, _ a: Selector) -> NSMenuItem { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.representedObject = tid; return i }
    menu.addItem(item("Close Tab", #selector(ctxClose(_:)))); menu.addItem(item("Sleep Tab", #selector(ctxSleep(_:))))
    menu.addItem(item("Open in New Window", #selector(ctxDetach(_:)))); menu.addItem(item("Copy Address", #selector(ctxCopy(_:))))
    if let h = engine.state.tabs[tid].flatMap({ URL(string: $0.url)?.host }) {
      let covering = engine.neverSleepEntry(covering: h)       // the list entry that actually protects this host (may be a parent domain)
      let i = item(covering.map { "Allow \($0) to Sleep" } ?? "Never Sleep \(h)", #selector(ctxNeverSleep(_:))); i.representedObject = h; menu.addItem(i)
    }
    let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: ""); let sub = NSMenu()
    for sp in engine.state.spaces where sp.id != space { let i = NSMenuItem(title: sp.name, action: #selector(ctxMove(_:)), keyEquivalent: ""); i.target = self; i.representedObject = [tid, sp.id]; sub.addItem(i) }
    move.submenu = sub; if sub.items.isEmpty { move.isEnabled = false }; menu.addItem(move)
  }
  @objc private func ctxClose(_ i: NSMenuItem) { if let t = i.representedObject as? TabID { closeTab(t) } }
  @objc private func ctxSleep(_ i: NSMenuItem) { if let t = i.representedObject as? TabID { Task { @MainActor in _ = await engine.lifecycle.sleepNow(t); refresh() } } }
  @objc private func ctxDetach(_ i: NSMenuItem) { if let t = i.representedObject as? TabID { _ = engine.detachTab(t) } }
  @objc private func ctxNeverSleep(_ i: NSMenuItem) { if let h = i.representedObject as? String { _ = try? engine.toggleNeverSleep(host: h); refresh() } }
  @objc private func ctxCopy(_ i: NSMenuItem) { if let t = i.representedObject as? TabID, let r = engine.state.tabs[t] { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.url, forType: .string) } }
  @objc private func ctxMove(_ i: NSMenuItem) {
    guard let a = i.representedObject as? [Any], let t = a[0] as? TabID, let s = a[1] as? SpaceID else { return }
    switch engine.moveTab(t, to: s) {
    case .needsProfileConfirmation:
      let al = NSAlert(); al.alertStyle = .warning; al.messageText = "Move to a different profile?"
      al.informativeText = "The destination space uses a different profile. The tab will sign in as that profile (separate logins and cookies)."
      al.addButton(withTitle: "Move"); al.addButton(withTitle: "Cancel")
      if al.runModal() == .alertFirstButtonReturn { _ = engine.moveTab(t, to: s, confirmedCrossProfile: true) }
    default: break
    }
  }

  // MARK: window delegate
  func windowWillClose(_ n: Notification) {
    guard !closingFromEngine else { return }
    closingFromEngine = true                      // we are handling this close ourselves: no re-entrant window.close() from syncWindows
    engine.closeWindow(id); app.controllers[id] = nil
  }
  func windowDidBecomeKey(_ n: Notification) { app.noteKey(id); if let s = selected { engine.lifecycle.activate(s) } }
}
