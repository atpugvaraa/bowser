import AppKit
import BrowserCore
import EngineCore
import Foundation

/// ⌘K palette: type to search open tabs, closed tabs, bookmarks and history; Enter opens, Esc closes, ↑/↓ move.
@MainActor
final class QuickOpenController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
  private let panel: NSPanel
  private let field = NSSearchField()
  private let table = NSTableView()
  private(set) var results: [QuickCandidate] = []
  private weak var owner: BrowserWindowController?
  var isVisible: Bool { panel.isVisible }

  override init() {
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 380), styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
    super.init()
    panel.title = "Quick Open"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true; panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.delegate = self
    let root = NSView(); panel.contentView = root
    field.placeholderString = "Search tabs, bookmarks and history…"; field.delegate = self; field.translatesAutoresizingMaskIntoConstraints = false
    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r")); col.resizingMask = .autoresizingMask; table.addTableColumn(col)
    table.headerView = nil; table.rowHeight = 38; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(chooseClicked)
    let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(field); root.addSubview(scroll)
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: root.topAnchor, constant: 30), field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  func show(for controller: BrowserWindowController) {
    owner = controller
    if let f = controller.window.frame as NSRect? { panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 320, y: f.maxY - 90)) }
    field.stringValue = ""; refresh()
    panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
  }
  func close() { panel.orderOut(nil) }

  // test hooks
  func setQuery(_ q: String) { field.stringValue = q; refresh() }
  @discardableResult func chooseFirst() -> Bool { guard !results.isEmpty else { return false }; table.selectRowIndexes([0], byExtendingSelection: false); choose(); return true }

  private func refresh() {
    results = owner?.app.engine.quickSearch(field.stringValue, limit: 30) ?? []
    table.reloadData()
    if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
  }
  func controlTextDidChange(_ n: Notification) { refresh() }
  func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    switch sel {
    case #selector(NSResponder.moveDown(_:)): move(+1); return true
    case #selector(NSResponder.moveUp(_:)): move(-1); return true
    case #selector(NSResponder.insertNewline(_:)): choose(); return true
    case #selector(NSResponder.cancelOperation(_:)): close(); return true
    default: return false
    }
  }
  private func move(_ d: Int) { guard !results.isEmpty else { return }; let r = min(max(table.selectedRow + d, 0), results.count - 1); table.selectRowIndexes([r], byExtendingSelection: false); table.scrollRowToVisible(r) }
  @objc private func chooseClicked() { choose() }
  private func choose() {
    guard let o = owner, table.selectedRow >= 0, table.selectedRow < results.count else { return }
    let c = results[table.selectedRow]; close()
    if case .focusWindow(let other)? = o.app.engine.openQuickResult(c, in: o.id) { o.app.controllers[other]?.window.makeKeyAndOrderFront(nil) }
    o.refresh()
  }
  func windowDidResignKey(_ n: Notification) { close() }

  // table
  func numberOfRows(in t: NSTableView) -> Int { results.count }
  func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    let c = results[row]; let cell = NSTableCellView()
    let sym = [QuickCandidate.Kind.openTab: "rectangle.on.rectangle", .bookmark: "star.fill", .closedTab: "arrow.uturn.backward.circle", .history: "clock"][c.kind] ?? "circle"
    let icon = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil) ?? NSImage()); icon.contentTintColor = c.kind == .openTab ? .systemGreen : .secondaryLabelColor; icon.translatesAutoresizingMaskIntoConstraints = false
    let title = NSTextField(labelWithString: c.title.isEmpty ? (URL(string: c.url)?.host ?? c.url) : c.title); title.lineBreakMode = .byTruncatingTail; title.translatesAutoresizingMaskIntoConstraints = false
    let url = NSTextField(labelWithString: c.url); url.textColor = .secondaryLabelColor; url.font = .systemFont(ofSize: 11); url.lineBreakMode = .byTruncatingMiddle; url.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(icon); cell.addSubview(title); cell.addSubview(url)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
      url.leadingAnchor.constraint(equalTo: title.leadingAnchor), url.trailingAnchor.constraint(equalTo: title.trailingAnchor), url.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
    ])
    return cell
  }
}
