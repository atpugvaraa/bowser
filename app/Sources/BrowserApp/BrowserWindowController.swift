import AppKit
import BrowserCore
import EngineCore
import EngineWebKit
import Foundation
import WebKit

enum PinnedItem: Equatable {
  case folder(FolderID, name: String, isExpanded: Bool)
  case tab(TabID, inFolder: Bool)
}

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
  let id: WindowID
  unowned let app: AppDelegate
  let window: NSWindow
  private let spacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let pinnedTable = ArcTableView()
  private let pinnedScroll = NSScrollView()
  private var pinnedHeightConstraint: NSLayoutConstraint?
  private var pinnedItems: [PinnedItem] = []
  private let table = ArcTableView()
  private let sidebar = AppKitSidebarContainerView()
  private let sidebarToggleBtn = NSButton()
  private let favoritesTray = FavoritesTrayView()
  private var favoritesHeightConstraint: NSLayoutConstraint?
  private let spacesDock = SpacesDockView()
  let commandBarOverlay = CommandBarOverlayView()
  private let divider = SidebarDividerView()
  private let newTabButton = NewTabHoverButton()
  private let backButton = NSButton(), forwardButton = NSButton(), reloadButton = NSButton()
  let addressField = NSTextField()
  private lazy var omniboxView = SidebarOmniboxView(addressField: addressField)
  var extButton: NSButton { spacesDock.extButton }
  private let progress = NSProgressIndicator()
  private let content = NSView()
  private var rows: [TabID] = []
  private var shownTab: TabID?
  private var updatingSelection = false
  private var closingFromEngine = false
  private var isSidebarVisible = true
  private var savedSidebarWidth: CGFloat = 260
  private var sidebarLeadingConstraint: NSLayoutConstraint?
  private var sidebarWidthConstraint: NSLayoutConstraint?
  private var engine: BrowserEngine { app.engine }

  var selected: TabID? { engine.state.windows[id]?.selected }
  var space: SpaceID? { engine.state.windows[id]?.space }
  var rowTitles: [String] { rows.map(title(for:)) }                    // for the self-test

  init(id: WindowID, app: AppDelegate) {
    self.id = id; self.app = app
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init()
    sidebar.controller = self
    pinnedTable.controller = self
    pinnedTable.target = self
    pinnedTable.action = #selector(pinnedTableClicked)
    table.controller = self
    spacesDock.controller = self
    newTabButton.target = self
    newTabButton.action = #selector(newTabClicked)
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
  private let mainTint = TintView(), cardOverlay = CardFrameOverlay()
  private func buildUI() {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
    let root = FlippedView(); window.contentView = root

    // Sidebar: solid matte charcoal surface, traffic lights sit in its top margin.
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    func style(_ b: NSButton, _ symbol: String, _ action: Selector, _ tip: String) {
      b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip); b.isBordered = false; b.imagePosition = .imageOnly; b.contentTintColor = .secondaryLabelColor
      b.target = self; b.action = action; b.toolTip = tip; b.translatesAutoresizingMaskIntoConstraints = false
      b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
      b.widthAnchor.constraint(equalToConstant: 28).isActive = true; b.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    style(sidebarToggleBtn, "sidebar.left", #selector(toggleSidebarClicked), "Toggle Sidebar")
    style(backButton, "chevron.left", #selector(backClicked), "Back"); style(forwardButton, "chevron.right", #selector(forwardClicked), "Forward"); style(reloadButton, "arrow.clockwise", #selector(reloadClicked), "Reload")
    let nav = NSStackView(views: [backButton, forwardButton, reloadButton]); nav.orientation = .horizontal; nav.spacing = 2; nav.alignment = .centerY; nav.translatesAutoresizingMaskIntoConstraints = false
    addressField.placeholderString = "Search or enter website"; addressField.bezelStyle = .roundedBezel; addressField.delegate = self; addressField.font = .systemFont(ofSize: 13)
    addressField.lineBreakMode = .byTruncatingTail; addressField.translatesAutoresizingMaskIntoConstraints = false; addressField.focusRingType = .none
    omniboxView.translatesAutoresizingMaskIntoConstraints = false
    omniboxView.onActivateLauncher = { [weak self] in self?.showCommandBar() }
    omniboxView.onCopyAddress = { [weak self] in self?.copyCurrentAddress() }
    favoritesTray.translatesAutoresizingMaskIntoConstraints = false
    favoritesTray.onDismiss = { [weak self] in
      self?.favoritesTray.isHidden = true
      self?.favoritesHeightConstraint?.constant = 0
    }
    favoritesTray.menuForFavorite = { [weak self] tid in self?.favoriteMenu(tid) }
    favoritesTray.onSelectFavorite = { [weak self] tid in self?.selectTab(tid) }
    spacePopup.target = self; spacePopup.action = #selector(spaceChanged(_:)); spacePopup.translatesAutoresizingMaskIntoConstraints = false; spacePopup.isBordered = false; spacePopup.font = .systemFont(ofSize: 12, weight: .semibold)
    divider.translatesAutoresizingMaskIntoConstraints = false
    newTabButton.translatesAutoresizingMaskIntoConstraints = false
    spacesDock.translatesAutoresizingMaskIntoConstraints = false
    commandBarOverlay.translatesAutoresizingMaskIntoConstraints = false
    commandBarOverlay.isHidden = true
    commandBarOverlay.commandBar.onDismiss = { [weak self] in self?.dismissCommandBar() }
    commandBarOverlay.commandBar.onSelect = { [weak self] item in self?.handleCommandBarSelect(item) }

    let pCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pinned")); pCol.resizingMask = .autoresizingMask; pinnedTable.addTableColumn(pCol)
    pinnedTable.headerView = nil; pinnedTable.rowHeight = 32; pinnedTable.style = .plain; pinnedTable.dataSource = self; pinnedTable.delegate = self; pinnedTable.intercellSpacing = NSSize(width: 0, height: 2)
    pinnedTable.allowsEmptySelection = true; pinnedTable.allowsMultipleSelection = false; pinnedTable.backgroundColor = .clear; pinnedTable.selectionHighlightStyle = .regular
    let pinnedMenu = NSMenu(); pinnedMenu.delegate = self; pinnedTable.menu = pinnedMenu
    pinnedScroll.documentView = pinnedTable; pinnedScroll.hasVerticalScroller = true; pinnedScroll.drawsBackground = false; pinnedScroll.translatesAutoresizingMaskIntoConstraints = false; pinnedScroll.scrollerStyle = .overlay
    pinnedScroll.isHidden = true

    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab")); col.resizingMask = .autoresizingMask; table.addTableColumn(col)
    table.headerView = nil; table.rowHeight = 32; table.style = .plain; table.dataSource = self; table.delegate = self; table.intercellSpacing = NSSize(width: 0, height: 2)
    table.allowsEmptySelection = true; table.allowsMultipleSelection = false; table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
    let menu = NSMenu(); menu.delegate = self; table.menu = menu
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.scrollerStyle = .overlay

    [nav, omniboxView, favoritesTray, spacePopup, pinnedScroll, divider, newTabButton, scroll, spacesDock].forEach { sidebar.addSubview($0) }

    sidebar.setAccessibilityIdentifier("ArcSidebar")
    sidebarToggleBtn.setAccessibilityIdentifier("ArcSidebarToggle")
    addressField.setAccessibilityIdentifier("ArcAddressField")
    omniboxView.setAccessibilityIdentifier("ArcOmnibox")
    favoritesTray.setAccessibilityIdentifier("ArcFavoritesTray")
    spacePopup.setAccessibilityIdentifier("ArcSpacePopup")
    newTabButton.setAccessibilityIdentifier("ArcNewTabButton")
    pinnedTable.setAccessibilityIdentifier("ArcPinnedTable")
    table.setAccessibilityIdentifier("ArcTabTable")
    spacesDock.setAccessibilityIdentifier("ArcSpacesDock")
    commandBarOverlay.commandBar.setAccessibilityIdentifier("ArcCommandBar")
    commandBarOverlay.commandBar.textField.setAccessibilityIdentifier("ArcCommandBarField")

    // Page area: a coloured frame with the page as a rounded card. The card's corners are painted over the web view (see CardFrameOverlay).
    progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.controlSize = .small; progress.isHidden = true; progress.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    mainTint.translatesAutoresizingMaskIntoConstraints = false; cardOverlay.translatesAutoresizingMaskIntoConstraints = false
    let main = FlippedView(); main.translatesAutoresizingMaskIntoConstraints = false
    [mainTint, content, progress, cardOverlay].forEach { main.addSubview($0) }

    root.addSubview(sidebar)
    root.addSubview(main)
    root.addSubview(sidebarToggleBtn)                  // outside the sidebar so it stays when the sidebar hides
    root.addSubview(commandBarOverlay)

    let lead = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
    let width = sidebar.widthAnchor.constraint(equalToConstant: savedSidebarWidth)
    self.sidebarLeadingConstraint = lead
    self.sidebarWidthConstraint = width

    let pHeight = pinnedScroll.heightAnchor.constraint(equalToConstant: 0)
    pHeight.isActive = true
    self.pinnedHeightConstraint = pHeight

    let fHeight = favoritesTray.heightAnchor.constraint(equalToConstant: 48)
    fHeight.isActive = true
    self.favoritesHeightConstraint = fHeight

    let pad: CGFloat = 8
    NSLayoutConstraint.activate([
      lead,
      width,
      sidebar.topAnchor.constraint(equalTo: root.topAnchor),
      sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

      // one line with the traffic lights (their centre is ~16pt down): toggle sits beside them outside the sidebar, back/forward/reload at the sidebar's right edge
      nav.centerYAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
      nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
      sidebarToggleBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 80),
      sidebarToggleBtn.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 16),

      omniboxView.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 42),
      omniboxView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
      omniboxView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
      omniboxView.heightAnchor.constraint(equalToConstant: 34),

      favoritesTray.topAnchor.constraint(equalTo: omniboxView.bottomAnchor, constant: 8),
      favoritesTray.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
      favoritesTray.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

      spacePopup.topAnchor.constraint(equalTo: favoritesTray.bottomAnchor, constant: 8),
      spacePopup.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
      spacePopup.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -8),

      pinnedScroll.topAnchor.constraint(equalTo: spacePopup.bottomAnchor, constant: 4),
      pinnedScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
      pinnedScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),

      divider.topAnchor.constraint(equalTo: pinnedScroll.bottomAnchor, constant: 4),
      divider.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),

      newTabButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
      newTabButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
      newTabButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
      newTabButton.heightAnchor.constraint(equalToConstant: 28),

      spacesDock.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -4),
      spacesDock.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
      spacesDock.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      spacesDock.heightAnchor.constraint(equalToConstant: 34),

      scroll.topAnchor.constraint(equalTo: newTabButton.bottomAnchor, constant: 6),
      scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
      scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
      scroll.bottomAnchor.constraint(equalTo: spacesDock.topAnchor, constant: -6),

      main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      main.topAnchor.constraint(equalTo: root.topAnchor),
      main.bottomAnchor.constraint(equalTo: root.bottomAnchor),

      commandBarOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      commandBarOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      commandBarOverlay.topAnchor.constraint(equalTo: root.topAnchor),
      commandBarOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),

      mainTint.leadingAnchor.constraint(equalTo: main.leadingAnchor),
      mainTint.trailingAnchor.constraint(equalTo: main.trailingAnchor),
      mainTint.topAnchor.constraint(equalTo: main.topAnchor),
      mainTint.bottomAnchor.constraint(equalTo: main.bottomAnchor),

      content.topAnchor.constraint(equalTo: main.topAnchor, constant: pad),
      content.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: pad),
      content.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -pad),
      content.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -pad),

      cardOverlay.leadingAnchor.constraint(equalTo: main.leadingAnchor),
      cardOverlay.trailingAnchor.constraint(equalTo: main.trailingAnchor),
      cardOverlay.topAnchor.constraint(equalTo: main.topAnchor),
      cardOverlay.bottomAnchor.constraint(equalTo: main.bottomAnchor),

      progress.topAnchor.constraint(equalTo: content.topAnchor),
      progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      progress.heightAnchor.constraint(equalToConstant: 3),
    ])
    applySpaceColours()
  }
  /// Re-tint the frame, sidebar and accents for the window's current space.
  private func applySpaceColours() {
    let sp = space.flatMap { engine.state.space($0) }
    mainTint.color = SpacePalette.frame(for: sp); cardOverlay.frameColor = SpacePalette.frame(for: sp)
    progress.contentFilters = []
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
    let sSig = engine.state.spaces.map { "\($0.id.raw)\($0.name)\($0.icon)\($0.profile.raw)\($0.colorHue ?? -1)" }.joined() + "|\(sp.id.raw)"
    if sSig != spaceSignature {
      spaceSignature = sSig; spacePopup.removeAllItems()
      for (i, s) in engine.state.spaces.enumerated() {
        let profName = engine.state.profile(s.profile)?.name ?? ""
        let title = !profName.isEmpty ? "\(s.icon) \(s.name) · \(profName)" : "\(s.icon) \(s.name)"
        spacePopup.addItem(withTitle: title); spacePopup.lastItem?.tag = i
      }
      if let i = engine.state.spaces.firstIndex(where: { $0.id == sp.id }) { spacePopup.selectItem(at: i) }
    }
    // Pinned items
    var newPinned: [PinnedItem] = []
    for fid in sp.folderOrder {
      guard let f = engine.state.folders[fid] else { continue }
      newPinned.append(.folder(fid, name: f.name, isExpanded: f.isExpanded))
      if f.isExpanded {
        let childTabs = sp.tabOrder.filter { engine.state.tabs[$0]?.folderId == fid }
        for tid in childTabs {
          newPinned.append(.tab(tid, inFolder: true))
        }
      }
    }
    let standalonePinned = sp.tabOrder.filter {
      let t = engine.state.tabs[$0]
      return t?.pinned == true && t?.folderId == nil
    }

    // Ora 3-column favorites grid
    let favTiles: [FavoriteTileData] = standalonePinned.prefix(6).map { tid in
      let t = engine.state.tabs[tid]
      let isSel = (w.selected == tid)
      return FavoriteTileData(id: tid, title: title(for: tid), url: t?.url ?? "", isSelected: isSel, isPlayingAudio: false)
    }
    var favIcons: [TabID: NSImage?] = [:]
    for tid in standalonePinned.prefix(6) {
      let host = engine.state.tabs[tid].flatMap { URL(string: $0.url)?.host } ?? ""
      favIcons[tid] = app.favicons.image(for: host)
    }
    favoritesTray.reloadFavorites(tiles: favTiles, icons: favIcons)
    if !favTiles.isEmpty { favoritesTray.isHidden = false }     // a dismissed empty tray must come back when something is pinned, or those tabs would be in no list
    if !favoritesTray.isHidden {
      let rowsCount = (favTiles.count + 2) / 3
      favoritesHeightConstraint?.constant = favTiles.isEmpty ? 48 : CGFloat(min(rowsCount, 2) * 44 + max(0, min(rowsCount, 2) - 1) * 8)
    }

    if standalonePinned.count > 6 {
      for tid in standalonePinned.dropFirst(6) {
        newPinned.append(.tab(tid, inFolder: false))
      }
    }
    pinnedItems = newPinned

    if pinnedItems.isEmpty {
      pinnedScroll.isHidden = true
      pinnedHeightConstraint?.constant = 0
    } else {
      pinnedScroll.isHidden = false
      pinnedHeightConstraint?.constant = min(CGFloat(pinnedItems.count) * 32, 220)
      pinnedTable.reloadData()
    }

    rows = sp.tabOrder.filter { engine.state.tabs[$0]?.pinned != true }
    let rSig = rows.map { "\($0.raw)|\(title(for: $0))|\(engine.tab($0)?.isLive ?? false)" }.joined(separator: "\n") + "#\(w.selected?.raw.uuidString ?? "")"
    if rSig != rowSignature {
      rowSignature = rSig
      updatingSelection = true
      table.reloadData()
      if let s = w.selected, let r = rows.firstIndex(of: s) {
        table.selectRowIndexes([r], byExtendingSelection: false)
        pinnedTable.deselectAll(nil)
      } else if let s = w.selected, let pr = pinnedItems.firstIndex(where: { if case .tab(let tid, _) = $0 { return tid == s } else { return false } }) {
        pinnedTable.selectRowIndexes([pr], byExtendingSelection: false)
        table.deselectAll(nil)
      } else {
        table.deselectAll(nil)
        pinnedTable.deselectAll(nil)
      }
      updatingSelection = false
    }
    applySpaceColours()
    spacesDock.reloadSpaces(spaces: engine.state.spaces, active: sp.id)
    fetchMissingIcons(for: sp.tabOrder)
    attachSelected()
    let t = w.selected.flatMap { engine.tab($0) }
    window.title = w.selected.map(title(for:)) ?? "Browser"
    window.subtitle = sp.name
    let liveURL = displayURL(w.selected)
    if !isEditingAddress { addressField.stringValue = liveURL }
    backButton.isEnabled = t?.canGoBack ?? false; forwardButton.isEnabled = t?.canGoForward ?? false
    let loading = t?.isLoadingPage ?? false
    omniboxView.updateStatus(url: liveURL, isLoading: loading)
    reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
    reloadButton.toolTip = loading ? "Stop" : "Reload"
    progress.isHidden = !loading; progress.doubleValue = t?.progress ?? 0
  }

  private func displayURL(_ id: TabID?) -> String {
    guard let id, let r = engine.state.tabs[id] else { return "" }
    let live = engine.tab(id)?.currentURL?.absoluteString ?? r.url
    return live == "about:blank" ? "" : live
  }
  private var isEditingAddress: Bool {
    guard let editor = addressField.currentEditor() else { return false }
    return window.firstResponder === editor
  }
  private func copyCurrentAddress() {
    guard let sel = selected, let r = engine.state.tabs[sel] else { return }
    let live = engine.tab(sel)?.currentURL?.absoluteString ?? r.url
    guard live != "about:blank", !live.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(live, forType: .string)
  }

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

  /// Ask the favicon store for icons of finished-loading, awake tabs (a few at a time; one try per site per run).
  private func fetchMissingIcons(for ids: [TabID]) {
    for id in ids {
      guard let tab = engine.tab(id) as? WebKitTab, tab.isLive, !tab.isLoadingPage, let url = tab.url ?? URL(string: engine.state.tabs[id]?.url ?? ""), let host = url.host, url.scheme == "https" || url.scheme == "http", app.favicons.wants(host) else { continue }
      let web = tab.webView, origin = (url.scheme ?? "https") + "://" + host + (url.port.map { ":\($0)" } ?? "")
      Task { @MainActor in await app.favicons.fetch(host: host, from: web, origin: origin) }
    }
  }

  // MARK: table
  func numberOfRows(in t: NSTableView) -> Int {
    if t === pinnedTable { return pinnedItems.count }
    return rows.count
  }
  func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let id = NSUserInterfaceItemIdentifier("ArcRow")
    if let rowView = t.makeView(withIdentifier: id, owner: self) as? ArcTableRowView {
      return rowView
    }
    let rowView = ArcTableRowView()
    rowView.identifier = id
    return rowView
  }
  func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    if t === pinnedTable {
      guard row < pinnedItems.count else { return nil }
      switch pinnedItems[row] {
      case .folder(_, let name, let isExpanded):
        return FolderCell(title: name, isExpanded: isExpanded)
      case .tab(let tid, let inFolder):
        let host = engine.state.tabs[tid].flatMap { URL(string: $0.url)?.host } ?? ""
        return TabCell(title: title(for: tid), icon: app.favicons.image(for: host), awake: engine.tab(tid)?.isLive ?? false, closeTarget: self, closeAction: #selector(closePinnedRowClicked(_:)), tag: row, indent: inFolder ? 30 : 14)
      }
    }
    guard row < rows.count else { return nil }
    let id = rows[row]
    let host = engine.state.tabs[id].flatMap { URL(string: $0.url)?.host } ?? ""
    return TabCell(title: title(for: id), icon: app.favicons.image(for: host), awake: engine.tab(id)?.isLive ?? false, closeTarget: self, closeAction: #selector(closeRowClicked(_:)), tag: row)
  }
  func tableViewSelectionDidChange(_ n: Notification) {
    guard !updatingSelection, let t = n.object as? NSTableView else { return }
    if t === table {
      guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
      pinnedTable.deselectAll(nil)
      selectTab(rows[table.selectedRow])
    }
  }
  @objc private func closeRowClicked(_ b: NSButton) {
    let row = table.row(for: b)
    let idx = (row >= 0 && row < rows.count) ? row : b.tag
    if idx >= 0 && idx < rows.count { closeTab(rows[idx]) }
  }
  @objc private func closePinnedRowClicked(_ b: NSButton) {
    let row = pinnedTable.row(for: b)
    let idx = (row >= 0 && row < pinnedItems.count) ? row : b.tag
    if idx >= 0 && idx < pinnedItems.count, case .tab(let tid, _) = pinnedItems[idx] {
      closeTab(tid)
    }
  }
  @objc private func pinnedTableClicked() {
    let row = pinnedTable.selectedRow
    guard row >= 0, row < pinnedItems.count else { return }
    switch pinnedItems[row] {
    case .folder(let fid, _, _):
      engine.toggleFolderExpanded(fid)
      refresh()
    case .tab(let tid, _):
      table.deselectAll(nil)
      selectTab(tid)
    }
  }

  func selectTab(_ tab: TabID) {
    switch engine.select(tab: tab, in: id) {
    case .focusWindow(let other): app.controllers[other]?.window.makeKeyAndOrderFront(nil); refresh()      // a tab can only be shown in one window
    default: break
    }
  }

  // MARK: actions
  @objc private func toggleSidebarClicked() { toggleSidebar() }

  @objc func newTabClicked() { showCommandBar() }

  func showCommandBar() {
    var items: [CommandBarItem] = []
    for sp in engine.state.spaces {
      for tid in sp.tabOrder {
        if let tab = engine.state.tabs[tid] {
          let host = URL(string: tab.url)?.host ?? ""
          let img = app.favicons.image(for: host) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
          let title = tab.title.isEmpty ? (tab.url == "about:blank" ? "New Tab" : tab.url) : tab.title
          items.append(CommandBarItem(icon: img, title: title, isSwitchToTab: true, tabId: tid, spaceId: sp.id, url: tab.url))
        }
      }
    }
    commandBarOverlay.commandBar.setInitialItems(items)
    commandBarOverlay.commandBar.textField.stringValue = ""
    commandBarOverlay.alphaValue = 0
    commandBarOverlay.barTop.constant = 136
    commandBarOverlay.isHidden = false
    commandBarOverlay.layoutSubtreeIfNeeded()
    NSAnimationContext.runAnimationGroup { ctx in            // fade in while settling up into place
      ctx.duration = 0.18
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
      ctx.allowsImplicitAnimation = true
      commandBarOverlay.animator().alphaValue = 1
      commandBarOverlay.barTop.animator().constant = 120
    }
    window.makeFirstResponder(commandBarOverlay.commandBar.textField)
  }

  func dismissCommandBar() {
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.12
      commandBarOverlay.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.commandBarOverlay.isHidden = true
        self.commandBarOverlay.alphaValue = 1
        if let s = self.selected, let wk = self.engine.tab(s) as? WebKitTab {
          self.window.makeFirstResponder(wk.webView)
        }
      }
    })
  }

  func handleCommandBarSelect(_ item: CommandBarItem) {
    dismissCommandBar()
    if let tid = item.tabId, let sp = item.spaceId {
      if sp != space {
        engine.switchSpace(window: id, to: sp)
      }
      selectTab(tid)
    } else if let u = item.url, !u.isEmpty {
      if let sel = selected, (engine.state.tabs[sel]?.url == "about:blank" || engine.state.tabs[sel]?.url.isEmpty == true) {
        _ = engine.navigate(tab: sel, input: u)
      } else if let sp = space, let newT = engine.newTab(in: sp, url: "about:blank", window: id) {
        _ = engine.navigate(tab: newT, input: u)
      }
    }
  }

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
  @objc func extensionsClicked() { app.extensions?.showMenu(from: extButton) }
  @objc private func backClicked() { back() }
  @objc private func forwardClicked() { forward() }
  @objc private func reloadClicked() { if selected.flatMap({ engine.tab($0)?.isLoadingPage }) == true { stop() } else { reload() } }
  func selectAdjacent(_ d: Int) {
    guard let s = selected, let i = rows.firstIndex(of: s), !rows.isEmpty else { return }
    selectTab(rows[(i + d + rows.count) % rows.count])
  }
  func selectTab(number n: Int) { if n >= 1, n <= rows.count { selectTab(rows[n == 9 ? rows.count - 1 : n - 1]) } }

  // sidebar & spaces
  func updateSidebarWidth(_ w: CGFloat) {
    savedSidebarWidth = w
    sidebarWidthConstraint?.constant = w
  }

  func toggleSidebar() {
    setSidebarVisible(!isSidebarVisible, animated: true)
  }

  func setSidebarVisible(_ visible: Bool, animated: Bool) {
    guard visible != isSidebarVisible else { return }
    isSidebarVisible = visible
    let targetLeading: CGFloat = visible ? 0 : -savedSidebarWidth
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.sidebarLeadingConstraint?.animator().constant = targetLeading
      }
    } else {
      sidebarLeadingConstraint?.constant = targetLeading
    }
  }

  func switchSpaceRelative(direction: Int) {
    let spaces = engine.state.spaces
    guard spaces.count > 1, let cur = space, let idx = spaces.firstIndex(where: { $0.id == cur }) else { return }
    let nextIdx = (idx + direction + spaces.count) % spaces.count
    switchSpace(index: nextIdx)
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
  }

  @objc private func spaceChanged(_ p: NSPopUpButton) { switchSpace(index: p.indexOfSelectedItem) }
  func switchSpace(index: Int) {
    guard index >= 0, index < engine.state.spaces.count else { return }
    engine.switchSpace(window: id, to: engine.state.spaces[index].id)
  }
  func newSpacePrompt() {
    let a = NSAlert(); a.messageText = "New Space"; a.informativeText = "A space groups tabs. A separate profile keeps its own logins and cookies."
    let icon = NSTextField(frame: NSRect(x: 0, y: 0, width: 44, height: 24)); icon.stringValue = "🪐"; icon.placeholderString = "Icon"
    let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 210, height: 24)); name.placeholderString = "Name"
    let row = NSStackView(views: [icon, name]); row.orientation = .horizontal; row.spacing = 6
    let sep = NSButton(checkboxWithTitle: "Separate profile (own logins and cookies)", target: nil, action: nil)
    let stack = NSStackView(views: [row, sep]); stack.orientation = .vertical; stack.alignment = .leading; stack.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
    a.accessoryView = stack; a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn, !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    let ic = icon.stringValue.trimmingCharacters(in: .whitespaces)
    createSpace(name: name.stringValue, icon: ic.isEmpty ? "🪐" : ic, separateProfile: sep.state == .on)
  }
  @discardableResult func createSpace(name: String, icon: String = "🪐", profile: ProfileID? = nil, separateProfile: Bool = false, colorHue: Double? = nil) -> SpaceID? {
    guard let cur = space.flatMap({ engine.state.space($0) }) else { return nil }
    let targetProfile = profile ?? (separateProfile ? engine.addProfile(name: "\(name) Profile") : cur.profile)
    let sp = engine.addSpace(name: name, icon: icon, profile: targetProfile, colorHue: colorHue)
    engine.switchSpace(window: id, to: sp)
    newTab(); return sp
  }
  @discardableResult func createSpace(name: String, separateProfile: Bool) -> SpaceID? {
    createSpace(name: name, icon: "🪐", profile: nil, separateProfile: separateProfile, colorHue: nil)
  }
  func editSpacePrompt(space targetID: SpaceID? = nil) {
    guard let target = (targetID ?? space).flatMap({ engine.state.space($0) }) else { return }
    let a = NSAlert(); a.messageText = "Edit Space"; a.informativeText = "Customize space icon, name, and profile."
    let iconField = NSTextField(frame: NSRect(x: 0, y: 0, width: 44, height: 24)); iconField.stringValue = target.icon
    let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 210, height: 24)); nameField.stringValue = target.name
    let row = NSStackView(views: [iconField, nameField]); row.orientation = .horizontal; row.spacing = 6

    let profLabel = NSTextField(labelWithString: "Profile (shared logins & cookies):")
    let profPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
    for (idx, p) in engine.state.profiles.enumerated() {
      profPopup.addItem(withTitle: p.name)
      profPopup.lastItem?.tag = idx
      if p.id == target.profile { profPopup.selectItem(at: idx) }
    }
    profPopup.addItem(withTitle: "+ Create New Isolated Profile…")
    profPopup.lastItem?.tag = -1

    let stack = NSStackView(views: [row, profLabel, profPopup]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 260, height: 95)
    a.accessoryView = stack; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
    let newIcon = iconField.stringValue.trimmingCharacters(in: .whitespaces)
    let tag = profPopup.selectedItem?.tag ?? 0
    let newProf: ProfileID
    if tag == -1 {
      newProf = engine.addProfile(name: "\(newName.isEmpty ? target.name : newName) Profile")
    } else if tag >= 0 && tag < engine.state.profiles.count {
      newProf = engine.state.profiles[tag].id
    } else {
      newProf = target.profile
    }

    if newProf != target.profile {
      let warn = NSAlert(); warn.alertStyle = .warning; warn.messageText = "Switch Profile for '\(target.name)'?"
      warn.informativeText = "This space will switch to a different profile. All open tabs in this space will reload under the new profile's logins and cookies."
      warn.addButton(withTitle: "Switch"); warn.addButton(withTitle: "Cancel")
      guard warn.runModal() == .alertFirstButtonReturn else { return }
    }
    engine.updateSpace(target.id, name: newName.isEmpty ? nil : newName, icon: newIcon.isEmpty ? nil : newIcon, profile: newProf)
    refresh()
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
  /// Favorites tiles used to be rows in the pinned table, which had these actions; keep them reachable by right-click.
  private func favoriteMenu(_ tid: TabID) -> NSMenu {
    let m = NSMenu()
    for (t, a) in [("Unpin Tab", #selector(ctxUnpin(_:))), ("Copy Address", #selector(ctxCopy(_:))), ("Close Tab", #selector(ctxClose(_:)))] {
      let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.representedObject = tid; m.addItem(i)
    }
    return m
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    func item(_ t: String, _ a: Selector, _ obj: Any?) -> NSMenuItem { let i = NSMenuItem(title: t, action: a, keyEquivalent: ""); i.target = self; i.representedObject = obj; return i }

    if menu === pinnedTable.menu {
      let row = pinnedTable.clickedRow
      guard row >= 0, row < pinnedItems.count else { return }
      switch pinnedItems[row] {
      case .folder(let fid, _, _):
        menu.addItem(item("New Tab in Folder", #selector(ctxNewTabInFolder(_:)), fid))
        menu.addItem(item("Rename Folder…", #selector(ctxRenameFolder(_:)), fid))
        menu.addItem(item("Delete Folder", #selector(ctxDeleteFolder(_:)), fid))
      case .tab(let tid, _):
        menu.addItem(item("Unpin Tab", #selector(ctxUnpin(_:)), tid))
        let folderMenu = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(item("None (Root Pinned)", #selector(ctxMoveToFolder(_:)), [tid, Optional<FolderID>.none as Any]))
        if let sp = space {
          for f in engine.state.folders(in: sp) {
            sub.addItem(item(f.name, #selector(ctxMoveToFolder(_:)), [tid, f.id]))
          }
        }
        folderMenu.submenu = sub
        menu.addItem(folderMenu)
        menu.addItem(item("Close Tab", #selector(ctxClose(_:)), tid))
      }
      return
    }

    let row = table.clickedRow; guard row >= 0, row < rows.count else { return }
    let tid = rows[row]
    menu.addItem(item("Pin Tab", #selector(ctxPin(_:)), tid))
    menu.addItem(item("New Folder…", #selector(ctxNewFolderPrompt(_:)), tid))

    let folderMenu = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
    let fSub = NSMenu()
    if let sp = space {
      for f in engine.state.folders(in: sp) {
        fSub.addItem(item(f.name, #selector(ctxMoveToFolder(_:)), [tid, f.id]))
      }
    }
    if !fSub.items.isEmpty {
      folderMenu.submenu = fSub
      menu.addItem(folderMenu)
    }

    menu.addItem(item("Close Tab", #selector(ctxClose(_:)), tid)); menu.addItem(item("Sleep Tab", #selector(ctxSleep(_:)), tid))
    menu.addItem(item("Open in New Window", #selector(ctxDetach(_:)), tid)); menu.addItem(item("Copy Address", #selector(ctxCopy(_:)), tid))
    if let h = engine.state.tabs[tid].flatMap({ URL(string: $0.url)?.host }) {
      let covering = engine.neverSleepEntry(covering: h)
      let i = item(covering.map { "Allow \($0) to Sleep" } ?? "Never Sleep \(h)", #selector(ctxNeverSleep(_:)), h)
      menu.addItem(i)
    }
    let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: ""); let sub = NSMenu()
    for sp in engine.state.spaces where sp.id != space { let i = item(sp.name, #selector(ctxMove(_:)), [tid, sp.id]); sub.addItem(i) }
    move.submenu = sub; if sub.items.isEmpty { move.isEnabled = false }; menu.addItem(move)
  }

  @objc private func ctxPin(_ i: NSMenuItem) {
    if let t = i.representedObject as? TabID {
      engine.setTabPinned(t, pinned: true)
      refresh()
    }
  }
  @objc private func ctxUnpin(_ i: NSMenuItem) {
    if let t = i.representedObject as? TabID {
      engine.setTabPinned(t, pinned: false)
      refresh()
    }
  }
  @objc private func ctxNewFolderPrompt(_ i: NSMenuItem) {
    guard let sp = space else { return }
    let a = NSAlert()
    a.messageText = "New Folder"
    a.informativeText = "Name for the new folder:"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    field.stringValue = "Folder"
    a.accessoryView = field
    a.addButton(withTitle: "Create")
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let fid = engine.addFolder(in: sp, name: name) else { return }
    if let tid = i.representedObject as? TabID {
      engine.setTabPinned(tid, pinned: true)
      engine.setTabFolder(tab: tid, folder: fid)
    }
    refresh()
  }
  @objc private func ctxMoveToFolder(_ i: NSMenuItem) {
    guard let a = i.representedObject as? [Any], let tid = a[0] as? TabID else { return }
    let targetFolder = a[1] as? FolderID
    engine.setTabPinned(tid, pinned: true)
    engine.setTabFolder(tab: tid, folder: targetFolder)
    refresh()
  }
  @objc private func ctxNewTabInFolder(_ i: NSMenuItem) {
    guard let fid = i.representedObject as? FolderID, let sp = space else { return }
    if let tid = engine.newTab(in: sp, url: "about:blank", window: id) {
      engine.setTabPinned(tid, pinned: true)
      engine.setTabFolder(tab: tid, folder: fid)
      refresh()
      focusAddress()
    }
  }
  @objc private func ctxRenameFolder(_ i: NSMenuItem) {
    guard let fid = i.representedObject as? FolderID, let f = engine.state.folders[fid] else { return }
    let a = NSAlert()
    a.messageText = "Rename Folder"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    field.stringValue = f.name
    a.accessoryView = field
    a.addButton(withTitle: "Rename")
    a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    if !name.isEmpty {
      engine.updateFolder(fid, name: name)
      refresh()
    }
  }
  @objc private func ctxDeleteFolder(_ i: NSMenuItem) {
    guard let fid = i.representedObject as? FolderID else { return }
    _ = engine.deleteFolder(fid)
    refresh()
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
