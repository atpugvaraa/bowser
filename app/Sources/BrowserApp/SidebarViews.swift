import AppKit
import BrowserCore

/// Colours for a space. Derived from the space id so every space has a stable, distinct tint without any stored setting (a colour picker comes later).
/// Dynamic colours: they follow light/dark automatically when drawn.
enum SpacePalette {
  static func hue(for id: SpaceID) -> CGFloat {
    let b = id.raw.uuid; return CGFloat((Int(b.0) << 8 | Int(b.1)) % 360) / 360
  }
  /// The strip of colour around the page and behind the sidebar.
  static func frame(for id: SpaceID?) -> NSColor {
    let h = id.map(hue) ?? 0.6
    return NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hue: h, saturation: 0.40, brightness: 0.20, alpha: 1) : NSColor(hue: h, saturation: 0.16, brightness: 0.95, alpha: 1) }
  }
  /// Accent for the selected tab, the space chip and the progress line.
  static func accent(for id: SpaceID?) -> NSColor {
    let h = id.map(hue) ?? 0.6
    return NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hue: h, saturation: 0.55, brightness: 0.85, alpha: 1) : NSColor(hue: h, saturation: 0.65, brightness: 0.70, alpha: 1) }
  }
  /// A calm colour for a site's letter chip (no favicon fetching yet).
  static func chip(for host: String) -> NSColor {
    var hash: UInt32 = 5381; for u in host.unicodeScalars { hash = hash &* 33 &+ u.value }
    let h = CGFloat(hash % 360) / 360
    return NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hue: h, saturation: 0.45, brightness: 0.55, alpha: 1) : NSColor(hue: h, saturation: 0.40, brightness: 0.80, alpha: 1) }
  }
}

/// Plain filled background that re-resolves its dynamic colour on every draw (and so follows dark mode).
final class TintView: NSView {
  var color: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
  override var isOpaque: Bool { true }
  override func draw(_ r: NSRect) { color.setFill(); r.fill() }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Draws the rounded corners and hairline of the page card on TOP of the web view instead of masking the web view with a corner radius.
/// Masking a web view forces offscreen compositing in Core Animation, which costs frame rate on video and WebGL; this view only paints four tiny corners.
final class CardFrameOverlay: NSView {
  var inset = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 8) { didSet { needsDisplay = true } }
  var radius: CGFloat = 10
  var frameColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
  override var isOpaque: Bool { false }
  override func hitTest(_ p: NSPoint) -> NSView? { nil }                    // never steals clicks from the page
  override func draw(_ dirty: NSRect) {
    let card = NSRect(x: inset.left, y: inset.bottom, width: bounds.width - inset.left - inset.right, height: bounds.height - inset.top - inset.bottom)
    let path = NSBezierPath(rect: bounds); path.append(NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)); path.windingRule = .evenOdd
    frameColor.setFill(); path.fill()
    NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
    let line = NSBezierPath(roundedRect: card.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius); line.lineWidth = 0.5; line.stroke()
  }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One row of the tab list: letter chip, title, close button on hover or selection. Sleeping tabs are dimmed.
final class TabCell: NSTableCellView {
  let chip = NSImageView(), label = NSTextField(labelWithString: ""), close = NSButton()
  private var tracking: NSTrackingArea?
  private var hovering = false { didSet { updateClose() } }
  override var backgroundStyle: NSView.BackgroundStyle { didSet { updateClose() } }

  /// `icon` is the site's own favicon; without one the chip is an empty rounded square.
  init(title: String, icon: NSImage?, awake: Bool, closeTarget: AnyObject, closeAction: Selector, tag: Int) {
    super.init(frame: .zero)
    chip.imageScaling = .scaleProportionallyUpOrDown; chip.wantsLayer = true; chip.layer?.cornerRadius = 4; chip.layer?.masksToBounds = true
    if let icon { chip.image = icon } else { chip.layer?.borderWidth = 1; chip.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor }
    chip.alphaValue = awake ? 1 : 0.5
    label.stringValue = title; label.lineBreakMode = .byTruncatingTail; label.font = .systemFont(ofSize: 13); label.textColor = awake ? .labelColor : .secondaryLabelColor
    close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab"); close.isBordered = false; close.imagePosition = .imageOnly
    close.contentTintColor = .secondaryLabelColor; close.target = closeTarget; close.action = closeAction; close.tag = tag; close.isHidden = true
    for v in [chip, label, close] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
    NSLayoutConstraint.activate([
      chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), chip.centerYAnchor.constraint(equalTo: centerYAnchor), chip.widthAnchor.constraint(equalToConstant: 18), chip.heightAnchor.constraint(equalToConstant: 18),
      label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 8), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
      close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), close.centerYAnchor.constraint(equalTo: centerYAnchor), close.widthAnchor.constraint(equalToConstant: 16),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
  private func updateClose() { close.isHidden = !(hovering || backgroundStyle == .emphasized) }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(t); tracking = t
  }
  override func mouseEntered(with e: NSEvent) { hovering = true }
  override func mouseExited(with e: NSEvent) { hovering = false }
}
