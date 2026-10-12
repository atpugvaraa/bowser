import AppKit
import BrowserCore
import EngineCore
import Foundation
import Lifecycle

/// Hibernation settings (all user-settable, validated on save). Times are in minutes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  unowned let app: AppDelegate
  let window: NSWindow
  private var fields: [String: NSTextField] = [:]
  private let enabled = NSButton(checkboxWithTitle: "Sleep idle tabs automatically", target: nil, action: nil)
  private let status = NSTextField(labelWithString: "")

  init(app: AppDelegate) {
    self.app = app
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
  ]

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
    let apply = NSButton(title: "Apply", target: self, action: #selector(applyClicked)); apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
    let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetClicked)); reset.bezelStyle = .rounded
    let buttons = NSStackView(views: [reset, apply]); buttons.spacing = 10
    stack.addArrangedSubview(buttons); stack.addArrangedSubview(status)
    let note = NSTextField(wrappingLabelWithString: "Closing a tab or window never deletes anything: tabs go to the archive (Reopen Closed Tab). Sleeping a tab frees its memory but keeps your logins; its page reloads when you open it.")
    note.textColor = .secondaryLabelColor; note.preferredMaxLayoutWidth = 420; stack.addArrangedSubview(note)
  }

  private func minutes(_ s: TimeInterval) -> String { String(Int((s / 60).rounded())) }
  private func load() {
    let c = app.engine.policy
    enabled.state = c.enabled ? .on : .off
    fields["defaultGrace"]?.stringValue = minutes(c.defaultGrace); fields["minGrace"]?.stringValue = minutes(c.minGrace)
    fields["criticalFloor"]?.stringValue = minutes(c.criticalFloor); fields["audibleGrace"]?.stringValue = minutes(c.audibleGrace)
    fields["maxLiveNormal"]?.stringValue = "\(c.maxLive.normal)"; fields["maxLiveWarning"]?.stringValue = "\(c.maxLive.warning)"; fields["maxLiveCritical"]?.stringValue = "\(c.maxLive.critical)"
    status.stringValue = ""
  }
  private func num(_ k: String) -> Double? { fields[k].flatMap { Double($0.stringValue.trimmingCharacters(in: .whitespaces)) } }

  /// Test hook: type values into the real fields and press Apply.
  func testApply(_ values: [String: String]) { for (k, v) in values { fields[k]?.stringValue = v }; applyClicked() }
  var statusText: String { status.stringValue }

  @objc private func applyClicked() {
    guard let dg = num("defaultGrace"), let mg = num("minGrace"), let cf = num("criticalFloor"), let ag = num("audibleGrace"),
          let ln = num("maxLiveNormal"), let lw = num("maxLiveWarning"), let lc = num("maxLiveCritical") else { status.stringValue = "Please enter numbers only."; status.textColor = .systemRed; return }
    var c = app.engine.policy
    c.enabled = enabled.state == .on
    c.defaultGrace = dg * 60; c.minGrace = mg * 60; c.criticalFloor = cf * 60; c.audibleGrace = ag * 60
    c.maxLive = .init(normal: Int(ln), warning: Int(lw), critical: Int(lc))
    do { try app.engine.updatePolicy(c); load(); status.stringValue = "Saved."; status.textColor = .systemGreen } catch { status.stringValue = "Couldn't save: \(error)"; status.textColor = .systemRed }
  }
  @objc private func resetClicked() {
    do { try app.engine.updatePolicy(.relaxed); load(); status.stringValue = "Back to defaults."; status.textColor = .secondaryLabelColor } catch { status.stringValue = "Couldn't save: \(error)"; status.textColor = .systemRed }
  }
}
