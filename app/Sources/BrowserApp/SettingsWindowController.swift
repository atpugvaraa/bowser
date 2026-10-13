import AppKit
import BrowserCore
import ContentBlocking
import EngineCore
import EngineWebKit
import Foundation
import Lifecycle

/// Hibernation settings (all user-settable, validated on save). Times are in minutes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  unowned let app: AppDelegate
  let window: NSWindow
  private var fields: [String: NSTextField] = [:]
  private let enabled = NSButton(checkboxWithTitle: "Sleep tabs by idle time (the awake-tab limits below always apply)", target: nil, action: nil)
  private let blockEnabled = NSButton(checkboxWithTitle: "Block ads and trackers (conservative list; Netflix, Prime and YouTube are always exempt)", target: nil, action: nil)
  private let blockAllow = NSTextField()
  private var loadedText: [String: String] = [:]
  private let status = NSTextField(labelWithString: "")

  init(app: AppDelegate) {
    self.app = app
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = "Settings"; window.isReleasedWhenClosed = false; window.delegate = self
    build(); load()
  }
  func show() { load(); window.center(); window.makeKeyAndOrderFront(nil) }

  private let spec: [(String, String, String)] = [
    ("defaultGrace", "Sleep a tab after (minutes idle)", "How long an unused tab stays awake. Tabs you return to often are kept longer; rarely used ones go sooner."),
    ("minGrace", "Never sooner than (minutes)", "Lower bound at normal memory use."),
    ("criticalFloor", "…even when memory is tight (minutes)", "Lower bound when macOS reports memory pressure."),
    ("audibleGrace", "After audio stops, keep awake (minutes)", "A paused video or podcast stays awake this long."),
    ("maxLiveNormal", "Awake tabs limit — normal memory", "Extra tabs beyond this are slept (oldest first). Tabs playing media or with unsaved input are never slept."),
    ("maxLiveWarning", "Awake tabs limit — memory warning", ""),
    ("maxLiveCritical", "Awake tabs limit — memory critical", ""),
    ("tabMemoryCap", "Stop a tab using more than (MB; 0 = automatic)", "Protects your Mac from a page that eats all memory. Automatic = a quarter of your RAM (2–8 GB). The stopped tab keeps its address; Reload runs it again."),
  ]
  private let neverSleep = NSTextField()
  private let identity = NSPopUpButton()
  private let appearance = NSPopUpButton()

  private func build() {
    let root = NSView(); window.contentView = root
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)])
    stack.addArrangedSubview(enabled)
    for (key, label, help) in spec {
      let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
      let l = NSTextField(labelWithString: label); l.widthAnchor.constraint(equalToConstant: 260).isActive = true
      let f = NSTextField(); f.widthAnchor.constraint(equalToConstant: 70).isActive = true; f.alignment = .right; f.toolTip = help; fields[key] = f
      row.addArrangedSubview(l); row.addArrangedSubview(f); stack.addArrangedSubview(row)
    }
    let ns = NSStackView(); ns.orientation = .vertical; ns.alignment = .leading; ns.spacing = 4
    let nl = NSTextField(labelWithString: "Never sleep these sites (comma-separated):"); neverSleep.placeholderString = "music.example, chat.example"; neverSleep.widthAnchor.constraint(equalToConstant: 420).isActive = true
    ns.addArrangedSubview(nl); ns.addArrangedSubview(neverSleep); stack.addArrangedSubview(ns)
    let il = NSTextField(labelWithString: "Tell websites this browser is:"); identity.addItems(withTitles: BrowserIdentity.allCases.map(\.title))
    identity.target = self; identity.action = #selector(identityChanged(_:))
    let irow = NSStackView(views: [il, identity]); irow.spacing = 8; stack.addArrangedSubview(irow)
    let ih = NSTextField(wrappingLabelWithString: "Safari is honest and works best. Pick Chrome, Firefox or Edge only for a site that refuses Safari; it is a disguise, the engine stays WebKit. Applies from each tab's next page load."); ih.textColor = .secondaryLabelColor; ih.preferredMaxLayoutWidth = 420; stack.addArrangedSubview(ih)
    let al = NSTextField(labelWithString: "Websites use:"); appearance.addItems(withTitles: PageAppearance.allCases.map(\.title))
    appearance.target = self; appearance.action = #selector(appearanceChanged(_:))
    let arow = NSStackView(views: [al, appearance]); arow.spacing = 8; stack.addArrangedSubview(arow)
    let ah = NSTextField(wrappingLabelWithString: "Follow system makes websites start in your Mac's light or dark mode and switch with it. The others force it for pages only; the browser itself keeps following the system."); ah.textColor = .secondaryLabelColor; ah.preferredMaxLayoutWidth = 420; stack.addArrangedSubview(ah)
    stack.addArrangedSubview(blockEnabled)
    let bl = NSTextField(labelWithString: "Don't block on these sites (comma-separated):"); blockAllow.placeholderString = "shop.example"; blockAllow.widthAnchor.constraint(equalToConstant: 420).isActive = true
    stack.addArrangedSubview(bl); stack.addArrangedSubview(blockAllow)
    let apply = NSButton(title: "Apply", target: self, action: #selector(applyClicked)); apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
    let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetClicked)); reset.bezelStyle = .rounded
    let buttons = NSStackView(views: [reset, apply]); buttons.spacing = 10
    stack.addArrangedSubview(buttons); stack.addArrangedSubview(status)
    let note = NSTextField(wrappingLabelWithString: "Closing a tab or window never deletes anything: tabs go to the archive (Reopen Closed Tab). Sleeping a tab frees its memory but keeps your logins; its page reloads when you open it.")
    note.textColor = .secondaryLabelColor; note.preferredMaxLayoutWidth = 420; stack.addArrangedSubview(note)
  }

  @objc private func appearanceChanged(_ p: NSPopUpButton) {
    let all = PageAppearance.allCases; guard p.indexOfSelectedItem >= 0, p.indexOfSelectedItem < all.count else { return }
    app.factory.setPageAppearance(all[p.indexOfSelectedItem])
  }
  @objc private func identityChanged(_ p: NSPopUpButton) {
    let all = BrowserIdentity.allCases; guard p.indexOfSelectedItem >= 0, p.indexOfSelectedItem < all.count else { return }
    app.factory.setIdentity(all[p.indexOfSelectedItem])
  }
  private func minutes(_ s: TimeInterval) -> String { String(Int((s / 60).rounded())) }
  private func load() {
    identity.selectItem(at: BrowserIdentity.allCases.firstIndex(of: BrowserIdentity.current) ?? 0)
    appearance.selectItem(at: PageAppearance.allCases.firstIndex(of: PageAppearance.current) ?? 0)
    let c = app.engine.policy
    enabled.state = c.enabled ? .on : .off
    fields["defaultGrace"]?.stringValue = minutes(c.defaultGrace); fields["minGrace"]?.stringValue = minutes(c.minGrace)
    fields["criticalFloor"]?.stringValue = minutes(c.criticalFloor); fields["audibleGrace"]?.stringValue = minutes(c.audibleGrace)
    fields["maxLiveNormal"]?.stringValue = "\(c.maxLive.normal)"; fields["maxLiveWarning"]?.stringValue = "\(c.maxLive.warning)"; fields["maxLiveCritical"]?.stringValue = "\(c.maxLive.critical)"
    fields["tabMemoryCap"]?.stringValue = "\(c.tabMemoryCapMB)"
    neverSleep.stringValue = c.neverSleepHosts.joined(separator: ", ")
    blockEnabled.state = app.blocking.enabled ? .on : .off; blockAllow.stringValue = app.blocking.allowlist.joined(separator: ", ")
    loadedText = fields.mapValues { $0.stringValue }; loadedText["enabled"] = "\(enabled.state.rawValue)"; loadedText["neverSleep"] = neverSleep.stringValue
    status.stringValue = ""
  }
  /// Finite, sane numbers only ("nan", "inf", "1e400" and absurd sizes are rejected, never trapped on).
  private func num(_ k: String, max: Double = 1_000_000) -> Double? {
    guard let d = fields[k].flatMap({ Double($0.stringValue.trimmingCharacters(in: .whitespaces)) }), d.isFinite, d >= 0, d <= max else { return nil }
    return d
  }
  /// Test hook: type values into the real fields and press Apply.
  func testApply(_ values: [String: String], neverSleepSites: String? = nil, blocking: Bool? = nil, blockAllowlist: String? = nil) {
    for (k, v) in values { fields[k]?.stringValue = v }
    if let n = neverSleepSites { neverSleep.stringValue = n }
    if let b = blocking { blockEnabled.state = b ? .on : .off }
    if let a = blockAllowlist { blockAllow.stringValue = a }
    applyClicked()
  }
  var statusText: String { status.stringValue }
  func perform(reset: Bool) { if reset { resetClicked() } }

  @objc private func applyClicked() {
    var c = app.engine.policy
    var problems: [String] = []
    // only fields the user actually changed are written (a stored 30 s value must not be rounded to 1 min by merely pressing Apply)
    func changed(_ k: String) -> Bool { fields[k]?.stringValue != loadedText[k] }
    func minutesField(_ k: String, _ apply: (Double) -> Void) {
      guard changed(k) else { return }
      if let m = num(k, max: 7 * 24 * 60) { apply(m * 60) } else { problems.append("\(k): enter a number of minutes") }
    }
    minutesField("defaultGrace") { c.defaultGrace = $0 }; minutesField("minGrace") { c.minGrace = $0 }
    minutesField("criticalFloor") { c.criticalFloor = $0 }; minutesField("audibleGrace") { c.audibleGrace = $0 }
    func limit(_ k: String) -> Int? { guard changed(k) else { return nil }; if let d = num(k, max: 100_000), let i = Int(exactly: d.rounded()), i >= 1 { return i }; problems.append("\(k): enter a whole number of tabs (1 or more)"); return nil }
    if let v = limit("maxLiveNormal") { c.maxLive.normal = v }; if let v = limit("maxLiveWarning") { c.maxLive.warning = v }; if let v = limit("maxLiveCritical") { c.maxLive.critical = v }
    if changed("tabMemoryCap") { if let d = num("tabMemoryCap", max: 131_072), let i = Int(exactly: d.rounded()), i == 0 || i >= 512 { c.tabMemoryCapMB = i } else { problems.append("tabMemoryCap: enter 0 (automatic) or at least 512 MB") } }
    if "\(enabled.state.rawValue)" != loadedText["enabled"] { c.enabled = enabled.state == .on }
    var rejected: [String] = []
    if neverSleep.stringValue != loadedText["neverSleep"] {
      let tokens = neverSleep.stringValue.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).map(String.init)
      var list: [String] = []; for t in tokens { let h = PolicyConfig.normalizeHost(t); if h.isEmpty { rejected.append(t) } else if !list.contains(h) { list.append(h) } }
      if list.count > 200 { rejected.append("(\(list.count - 200) entries beyond the 200-site limit)"); list = Array(list.prefix(200)) }
      c.neverSleepHosts = list
    }
    if !problems.isEmpty { status.stringValue = "Not saved — " + problems.joined(separator: "; "); status.textColor = .systemRed; return }
    do {
      try app.engine.updatePolicy(c)
      let applied = app.engine.policy
      var notes: [String] = []
      if applied.minGrace != c.minGrace || applied.defaultGrace != c.defaultGrace || applied.criticalFloor != c.criticalFloor || applied.maxLive.normal != c.maxLive.normal { notes.append("some values were adjusted to safe limits") }
      if !rejected.isEmpty { notes.append("ignored: " + rejected.joined(separator: ", ")) }
      applyBlockingFromFields()
      load(); status.stringValue = notes.isEmpty ? "Saved." : "Saved — " + notes.joined(separator: "; "); status.textColor = notes.isEmpty ? .systemGreen : .systemOrange
    } catch { status.stringValue = "Couldn't save: \(error)"; status.textColor = .systemRed }
  }

  private func applyBlockingFromFields() {
    var b = BlockingSettings(); b.enabled = blockEnabled.state == .on
    b.allowlist = blockAllow.stringValue.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).map { BlockingSettings.normalize(String($0)) }.filter { !$0.isEmpty }
    guard b != app.blocking else { return }
    Task { @MainActor in do { try await app.applyBlocking(b) } catch { status.stringValue = "Blocking couldn't be changed: \(error)"; status.textColor = .systemRed } }
  }

  @objc private func resetClicked() {
    var d = PolicyConfig.relaxed; d.neverSleepHosts = app.engine.policy.neverSleepHosts       // your site list is YOURS: a reset keeps it
    do { try app.engine.updatePolicy(d); load(); status.stringValue = "Timings reset to defaults. Your never-sleep sites were kept."; status.textColor = .secondaryLabelColor }
    catch { status.stringValue = "Couldn't save: \(error)"; status.textColor = .systemRed }
  }
}
