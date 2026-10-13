import AppKit
import BrowserCore

/// Colours for a space. Derived from the space id so every space has a stable, distinct tint without any stored setting (a colour picker comes later).
/// Dynamic colours: they follow light/dark automatically when drawn.
enum SpacePalette {
  static func hue(for id: SpaceID) -> CGFloat {
    let b = id.raw.uuid; return CGFloat((Int(b.0) << 8 | Int(b.1)) % 360) / 360
  }
  static func hue(for space: Space?) -> CGFloat {
    if let ch = space?.colorHue { return CGFloat(ch) }
    guard let id = space?.id else { return 0.6 }
    return hue(for: id)
  }
  /// The strip of colour around the page and behind the sidebar.
  static func frame(for id: SpaceID?) -> NSColor {
    frame(withHue: id.map(hue) ?? 0.6)
  }
  static func frame(for space: Space?) -> NSColor {
    frame(withHue: hue(for: space))
  }
  private static func frame(withHue h: CGFloat) -> NSColor {
    NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hue: h, saturation: 0.40, brightness: 0.20, alpha: 1) : NSColor(hue: h, saturation: 0.16, brightness: 0.95, alpha: 1) }
  }
  /// Accent for the selected tab, the space chip and the progress line.
  static func accent(for id: SpaceID?) -> NSColor {
    accent(withHue: id.map(hue) ?? 0.6)
  }
  static func accent(for space: Space?) -> NSColor {
    accent(withHue: hue(for: space))
  }
  private static func accent(withHue h: CGFloat) -> NSColor {
    NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hue: h, saturation: 0.55, brightness: 0.85, alpha: 1) : NSColor(hue: h, saturation: 0.65, brightness: 0.70, alpha: 1) }
  }
  /// A calm colour for a site's letter chip (no favicon fetching yet).
  static func chip(for host: String) -> NSColor {
    var hash: UInt32 = 5381; for u in host.unicodeScalars { hash = hash &* 33 &+ u.value }
    let h = CGFloat(hash % 360) / 360
    return NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hue: h, saturation: 0.45, brightness: 0.55, alpha: 1) : NSColor(hue: h, saturation: 0.40, brightness: 0.80, alpha: 1) }
  }
}

/// Matte opaque background for the sidebar (replaces distracting translucency with a solid charcoal finish).
final class MatteBackgroundView: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let color = NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(red: 0.115, green: 0.115, blue: 0.125, alpha: 1.0) // #1d1d20 matte dark charcoal
        : NSColor(red: 0.955, green: 0.955, blue: 0.965, alpha: 1.0) // clean matte light
    }
    color.setFill()
    dirtyRect.intersection(bounds).fill()
  }
}

/// Subtle 0.5pt divider line separating pinned items from unpinned tabs.
final class SidebarDividerView: NSView {
  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) {
    let line = NSBezierPath()
    let y = floor(bounds.midY) + 0.5
    line.move(to: NSPoint(x: 10, y: y))
    line.line(to: NSPoint(x: bounds.width - 10, y: y))
    line.lineWidth = 0.5
    NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1.0, alpha: 0.12) : NSColor(white: 0.0, alpha: 0.10)
    }.setStroke()
    line.stroke()
  }
}

/// Arc-style "+ New Tab" button positioned directly above the unpinned tab list.
final class NewTabHoverButton: NSButton {
  private var trackingArea: NSTrackingArea?
  private var isHovered = false { didSet { needsDisplay = true } }

  init(target: AnyObject? = nil, action: Selector? = nil) {
    super.init(frame: .zero)
    self.target = target; self.action = action
    self.isBordered = false
    self.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
    self.title = "New Tab"
    self.imagePosition = .imageLeading
    self.contentTintColor = .secondaryLabelColor
    self.alignment = .left
    self.font = .systemFont(ofSize: 13, weight: .regular)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = trackingArea { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(t); trackingArea = t
  }
  override func mouseEntered(with e: NSEvent) { isHovered = true }
  override func mouseExited(with e: NSEvent) { isHovered = false }

  override func draw(_ dirtyRect: NSRect) {
    if isHovered {
      let rect = bounds.insetBy(dx: 4, dy: 1)
      let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
      NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1.0, alpha: 0.07) : NSColor(white: 0.0, alpha: 0.05)
      }.setFill()
      path.fill()
    }
    super.draw(dirtyRect)
  }
}

extension NSView {
  /// CALayer colours are plain CGColors, resolved once. Re-call this from viewDidChangeEffectiveAppearance so dynamic NSColors follow light/dark.
  func cg(_ c: NSColor) -> CGColor { var r = c.cgColor; effectiveAppearance.performAsCurrentDrawingAppearance { r = c.cgColor }; return r }
}

/// An NSView with flipped geometry (origin at top-left, Y increases downward), matching modern layout standards.
class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// Thin strip on the window's left edge: hovering it while the sidebar is hidden slides the sidebar out over the page (Arc).
final class SidebarEdgeView: NSView {
  var onHover: (() -> Void)?
  private var area: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); if let t = area { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(t); area = t
  }
  override func mouseEntered(with event: NSEvent) { onHover?() }
}

/// Dedicated sidebar container view handling matte background drawing, edge-drag resizing, and trackpad space gestures.
final class AppKitSidebarContainerView: FlippedView {
  weak var controller: BrowserWindowController?
  private var accumulatedDeltaX: CGFloat = 0
  private var swipedInCurrentGesture = false
  private var isDraggingDivider = false
  private var dragStartX: CGFloat = 0
  private var initialWidthOnDrag: CGFloat = 0

  override var isOpaque: Bool { true }
  var onMouseExit: (() -> Void)?
  private var exitArea: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); if let t = exitArea { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(t); exitArea = t
  }
  override func mouseExited(with event: NSEvent) { onMouseExit?() }
  /// The space's frame colour: sidebar and the strip around the page are one tinted surface (Arc), the page card floats on it.
  var fillColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    fillColor.setFill()
    dirtyRect.intersection(bounds).fill()
  }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

  override func resetCursorRects() {
    super.resetCursorRects()
    let resizeRect = NSRect(x: bounds.width - 4, y: 0, width: 4, height: bounds.height)
    addCursorRect(resizeRect, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    let loc = convert(event.locationInWindow, from: nil)
    if loc.x >= bounds.width - 6 {
      isDraggingDivider = true
      dragStartX = event.locationInWindow.x
      initialWidthOnDrag = bounds.width
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if isDraggingDivider, let ctrl = controller {
      let delta = event.locationInWindow.x - dragStartX
      let newW = max(200, min(420, initialWidthOnDrag + delta))
      ctrl.updateSidebarWidth(newW)
      return
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if isDraggingDivider {
      isDraggingDivider = false
      return
    }
    super.mouseUp(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    if event.hasPreciseScrollingDeltas {
      let dx = event.scrollingDeltaX
      let dy = event.scrollingDeltaY
      if abs(dx) > abs(dy) * 1.5 {
        accumulatedDeltaX += dx
        if event.phase == .began { swipedInCurrentGesture = false }
        let threshold: CGFloat = 30
        if !swipedInCurrentGesture && abs(accumulatedDeltaX) > threshold {
          swipedInCurrentGesture = true
          if accumulatedDeltaX > 0 {
            controller?.switchSpaceRelative(direction: -1)
          } else {
            controller?.switchSpaceRelative(direction: 1)
          }
        }
        if event.phase == .ended || event.phase == .cancelled {
          accumulatedDeltaX = 0
          swipedInCurrentGesture = false
        }
        return
      }
    }
    super.scrollWheel(with: event)
  }
}

/// Custom NSTableView that forwards horizontal two-finger trackpad swipes to space switching while preserving normal vertical tab scrolling.
final class ArcTableView: NSTableView {
  weak var controller: BrowserWindowController?
  private var accumulatedDeltaX: CGFloat = 0
  private var swipedInCurrentGesture = false

  override func scrollWheel(with event: NSEvent) {
    if event.hasPreciseScrollingDeltas {
      let dx = event.scrollingDeltaX
      let dy = event.scrollingDeltaY
      if abs(dx) > abs(dy) * 1.5 {
        accumulatedDeltaX += dx
        if event.phase == .began { swipedInCurrentGesture = false }
        let threshold: CGFloat = 30
        if !swipedInCurrentGesture && abs(accumulatedDeltaX) > threshold {
          swipedInCurrentGesture = true
          if accumulatedDeltaX > 0 {
            controller?.switchSpaceRelative(direction: -1)
          } else {
            controller?.switchSpaceRelative(direction: 1)
          }
        }
        if event.phase == .ended || event.phase == .cancelled {
          accumulatedDeltaX = 0
          swipedInCurrentGesture = false
        }
        return
      }
    }
    super.scrollWheel(with: event)
  }
}

/// Custom table row view rendering Arc-style rounded capsule pill selection and hover effects.
final class ArcTableRowView: NSTableRowView {
  private var trackingArea: NSTrackingArea?
  private var isHovered = false { didSet { needsDisplay = true } }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = trackingArea { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(t); trackingArea = t
  }
  override func mouseEntered(with e: NSEvent) { isHovered = true }
  override func mouseExited(with e: NSEvent) { isHovered = false }

  override func drawSelection(in dirtyRect: NSRect) {
    if isSelected {
      let rect = bounds.insetBy(dx: 6, dy: 1)
      let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
      let pillColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? NSColor(white: 0.23, alpha: 1.0) // #3b3b3d dark capsule pill
          : NSColor(white: 0.88, alpha: 1.0) // #e0e0e3 light pill
      }
      pillColor.setFill()
      path.fill()
    }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    if !isSelected && isHovered {
      let rect = bounds.insetBy(dx: 6, dy: 1)
      let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
      let hoverColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1.0, alpha: 0.06) : NSColor(white: 0.0, alpha: 0.04)
      }
      hoverColor.setFill()
      path.fill()
    }
  }
}

/// Plain filled background that re-resolves its dynamic colour on every draw (and so follows dark mode).
final class TintView: NSView {
  var color: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
  override var isOpaque: Bool { true }
  override func draw(_ r: NSRect) { color.setFill(); r.intersection(bounds).fill() }   // never paint outside our own frame (it sits above the sidebar in z-order)
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Draws the rounded corners and hairline of the page card on TOP of the web view instead of masking the web view with a corner radius.
/// Masking a web view forces offscreen compositing in Core Animation, which costs frame rate on video and WebGL; this view only paints four tiny corners.
final class CardFrameOverlay: FlippedView {
  var inset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8) { didSet { needsDisplay = true } }
  var radius: CGFloat = 10
  var frameColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
  override var isOpaque: Bool { false }
  override func hitTest(_ p: NSPoint) -> NSView? { nil }                    // never steals clicks from the page
  override func draw(_ dirty: NSRect) {
    let card = NSRect(x: inset.left, y: inset.top, width: bounds.width - inset.left - inset.right, height: bounds.height - inset.top - inset.bottom)
    let path = NSBezierPath(rect: bounds); path.append(NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)); path.windingRule = .evenOdd
    frameColor.setFill(); path.fill()
    NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
    let line = NSBezierPath(roundedRect: card.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius); line.lineWidth = 0.5; line.stroke()
  }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One row of the tab list: letter chip, audio icon, title, close button on hover or selection. Sleeping tabs are dimmed.
final class TabCell: NSTableCellView {
  let chip = NSImageView()
  let audioIcon = NSImageView()
  let label = NSTextField(labelWithString: "")
  let close = NSButton()
  private var tracking: NSTrackingArea?
  private var hovering = false { didSet { updateClose() } }
  override var backgroundStyle: NSView.BackgroundStyle { didSet { updateClose() } }
  private var leadingConstraint: NSLayoutConstraint?

  /// `icon` is the site's own favicon; without one the chip is an empty rounded square.
  init(title: String, icon: NSImage?, awake: Bool, isPlayingAudio: Bool = false, closeTarget: AnyObject, closeAction: Selector, tag: Int, indent: CGFloat = 12) {
    super.init(frame: .zero)
    chip.imageScaling = .scaleProportionallyUpOrDown
    chip.wantsLayer = true
    chip.layer?.cornerRadius = 4
    chip.layer?.masksToBounds = true
    if let icon {
      chip.image = icon
    } else {
      chip.layer?.borderWidth = 1
      chip.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
    }
    chip.alphaValue = awake ? 1 : 0.55

    audioIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing Audio")
    audioIcon.contentTintColor = .secondaryLabelColor
    audioIcon.imageScaling = .scaleProportionallyUpOrDown
    audioIcon.isHidden = !isPlayingAudio

    label.stringValue = title
    label.lineBreakMode = .byTruncatingTail
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = awake ? .labelColor : .secondaryLabelColor

    close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
    close.isBordered = false
    close.imagePosition = .imageOnly
    close.contentTintColor = .secondaryLabelColor
    close.target = closeTarget
    close.action = closeAction
    close.tag = tag
    close.isHidden = true

    for v in [chip, audioIcon, label, close] {
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
    }

    let lead = chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent)
    self.leadingConstraint = lead

    NSLayoutConstraint.activate([
      lead,
      chip.centerYAnchor.constraint(equalTo: centerYAnchor),
      chip.widthAnchor.constraint(equalToConstant: 16),
      chip.heightAnchor.constraint(equalToConstant: 16),

      audioIcon.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 4),
      audioIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      audioIcon.widthAnchor.constraint(equalToConstant: 12),
      audioIcon.heightAnchor.constraint(equalToConstant: 12),

      label.leadingAnchor.constraint(equalTo: isPlayingAudio ? audioIcon.trailingAnchor : chip.trailingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),

      close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      close.centerYAnchor.constraint(equalTo: centerYAnchor),
      close.widthAnchor.constraint(equalToConstant: 14),
      close.heightAnchor.constraint(equalToConstant: 14),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  func configure(title: String, icon: NSImage?, awake: Bool, isPlayingAudio: Bool, tag: Int, indent: CGFloat) {
    leadingConstraint?.constant = indent
    label.stringValue = title
    label.textColor = awake ? .labelColor : .secondaryLabelColor
    if let icon {
      chip.image = icon
      chip.layer?.borderWidth = 0
    } else {
      chip.image = nil
      chip.layer?.borderWidth = 1
      chip.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
    }
    chip.alphaValue = awake ? 1 : 0.55
    audioIcon.isHidden = !isPlayingAudio
    close.tag = tag
    updateClose()
  }

  private func updateClose() { close.isHidden = !(hovering || backgroundStyle == .emphasized) }
  override func viewDidChangeEffectiveAppearance() { if chip.layer?.borderWidth == 1 { chip.layer?.borderColor = cg(.tertiaryLabelColor) } }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self); addTrackingArea(t); tracking = t
  }
  override func mouseEntered(with e: NSEvent) { hovering = true }
  override func mouseExited(with e: NSEvent) { hovering = false }
}

/// One row representing a collapsible folder in Arc's pinned sidebar section.
final class FolderCell: NSTableCellView {
  let chevron = NSImageView()
  let folderIcon = NSImageView()
  let label = NSTextField(labelWithString: "")

  init(title: String, isExpanded: Bool) {
    super.init(frame: .zero)
    chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    chevron.contentTintColor = .secondaryLabelColor
    chevron.imageScaling = .scaleProportionallyUpOrDown

    folderIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
    folderIcon.contentTintColor = .secondaryLabelColor
    folderIcon.imageScaling = .scaleProportionallyUpOrDown

    label.stringValue = title
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail

    [chevron, folderIcon, label].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    NSLayoutConstraint.activate([
      chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 10),
      chevron.heightAnchor.constraint(equalToConstant: 10),

      folderIcon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
      folderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      folderIcon.widthAnchor.constraint(equalToConstant: 16),
      folderIcon.heightAnchor.constraint(equalToConstant: 16),

      label.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Sidebar URL Display (Omnibox Capsule)

/// Ora-style floating capsule URL display / address bar pill.
final class SidebarOmniboxView: FlippedView {
  let statusIcon = NSImageView()
  let spinner = NSProgressIndicator()
  let addressField: NSTextField
  let copyButton = NSButton()
  var onActivateLauncher: (() -> Void)?
  var onCopyAddress: (() -> Void)?
  private var isHovered = false { didSet { needsDisplay = true } }
  private var trackingArea: NSTrackingArea?

  init(addressField: NSTextField) {
    self.addressField = addressField
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.masksToBounds = true

    statusIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
    statusIcon.contentTintColor = .secondaryLabelColor
    statusIcon.imageScaling = .scaleProportionallyUpOrDown
    statusIcon.translatesAutoresizingMaskIntoConstraints = false

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.translatesAutoresizingMaskIntoConstraints = false

    addressField.isBordered = false
    addressField.drawsBackground = false
    addressField.font = .systemFont(ofSize: 13, weight: .regular)
    addressField.lineBreakMode = .byTruncatingTail
    addressField.focusRingType = .none
    addressField.translatesAutoresizingMaskIntoConstraints = false

    copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Address")
    copyButton.isBordered = false
    copyButton.imagePosition = .imageOnly
    copyButton.contentTintColor = .secondaryLabelColor
    copyButton.target = self
    copyButton.action = #selector(copyClicked)
    copyButton.toolTip = "Copy Address"
    copyButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(statusIcon)
    addSubview(spinner)
    addSubview(addressField)
    addSubview(copyButton)

    NSLayoutConstraint.activate([
      statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusIcon.widthAnchor.constraint(equalToConstant: 14),
      statusIcon.heightAnchor.constraint(equalToConstant: 14),

      spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 14),
      spinner.heightAnchor.constraint(equalToConstant: 14),

      addressField.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 6),
      addressField.centerYAnchor.constraint(equalTo: centerYAnchor),
      addressField.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
      addressField.heightAnchor.constraint(equalToConstant: 22),

      copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      copyButton.widthAnchor.constraint(equalToConstant: 18),
      copyButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = trackingArea { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(t); trackingArea = t
  }
  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
    let fill = NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(white: 1.0, alpha: self.isHovered ? 0.11 : 0.07)
        : NSColor(white: 0.0, alpha: self.isHovered ? 0.08 : 0.05)
    }
    fill.setFill()
    path.fill()

    let stroke = NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(white: 1.0, alpha: 0.08)
        : NSColor(white: 0.0, alpha: 0.08)
    }
    stroke.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  private var hasAddress = false
  func updateStatus(url: String, isLoading: Bool) {
    hasAddress = !url.isEmpty && url != "about:blank"
    if isLoading {
      spinner.isHidden = false
      spinner.startAnimation(nil)
      statusIcon.isHidden = true
    } else {
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      statusIcon.isHidden = false
      if url.isEmpty || url == "about:blank" {
        statusIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        statusIcon.contentTintColor = .secondaryLabelColor
      } else if let u = URL(string: url), u.scheme == "https" {
        statusIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")
        statusIcon.contentTintColor = .secondaryLabelColor
      } else if let sc = URL(string: url)?.scheme?.lowercased(), sc != "http", sc != "ftp" {          // file:, about:, view-source:... are not "insecure web"
        statusIcon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: "Local page")
        statusIcon.contentTintColor = .secondaryLabelColor
      } else {
        statusIcon.image = NSImage(systemSymbolName: "shield.slash", accessibilityDescription: "Not Secure")
        statusIcon.contentTintColor = .systemOrange
      }
    }
  }

  @objc private func copyClicked() {
    onCopyAddress?()
    guard hasAddress else { return }                      // nothing was copied: no checkmark
    copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    copyButton.contentTintColor = .systemGreen
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Address")
      self?.copyButton.contentTintColor = .secondaryLabelColor
    }
  }

  override func mouseDown(with event: NSEvent) {
    let loc = convert(event.locationInWindow, from: nil)
    if copyButton.frame.contains(loc) {
      super.mouseDown(with: event)
    } else {
      onActivateLauncher?()
    }
  }
}

// MARK: - Favorites Grid View (Ora FavTabsGrid)

/// Favorite item descriptor for Ora-style 3-column favorites grid.
public struct FavoriteTileData: Sendable, Equatable {
  public let id: TabID
  public let title: String
  public let url: String
  public let isSelected: Bool
  public let isPlayingAudio: Bool

  public init(id: TabID, title: String, url: String, isSelected: Bool = false, isPlayingAudio: Bool = false) {
    self.id = id; self.title = title; self.url = url; self.isSelected = isSelected; self.isPlayingAudio = isPlayingAudio
  }
}

final class FavTileButton: NSButton {
  let item: FavoriteTileData?
  var menuProvider: (() -> NSMenu?)?
  override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
  private let iconView = NSImageView()
  private let speakerIcon = NSImageView()
  private var isHovered = false { didSet { needsDisplay = true } }
  private var trackingArea: NSTrackingArea?

  init(item: FavoriteTileData, icon: NSImage?) {
    self.item = item
    super.init(frame: .zero)
    isBordered = false
    title = ""
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.masksToBounds = true
    toolTip = item.title.isEmpty ? item.url : "\(item.title)\n\(item.url)"

    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.image = icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    iconView.wantsLayer = true
    iconView.layer?.cornerRadius = 4
    iconView.layer?.masksToBounds = true
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    speakerIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Audio")
    speakerIcon.contentTintColor = .white
    speakerIcon.isHidden = !item.isPlayingAudio
    speakerIcon.translatesAutoresizingMaskIntoConstraints = false
    addSubview(speakerIcon)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      speakerIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      speakerIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      speakerIcon.widthAnchor.constraint(equalToConstant: 10),
      speakerIcon.heightAnchor.constraint(equalToConstant: 10),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = trackingArea { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(t); trackingArea = t
  }
  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
    if item?.isSelected == true {
      let selColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? NSColor(white: 0.25, alpha: 1.0)
          : NSColor(white: 0.85, alpha: 1.0)
      }
      selColor.setFill()
      path.fill()
    } else if isHovered {
      let hoverColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? NSColor(white: 1.0, alpha: 0.08)
          : NSColor(white: 0.0, alpha: 0.06)
      }
      hoverColor.setFill()
      path.fill()
    } else {
      let tileColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? NSColor(white: 1.0, alpha: 0.04)
          : NSColor(white: 0.0, alpha: 0.03)
      }
      tileColor.setFill()
      path.fill()
    }
    super.draw(dirtyRect)
  }
}

/// Favorites container that renders Ora's 3-column grid when favorites exist, or dashed hint card when empty.
final class FavoritesTrayView: FlippedView {
  private let starIcon = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "Drag to add Favorites")
  private let subtitleLabel = NSTextField(labelWithString: "Favorites keep your most used sites and apps close")
  private let closeButton = NSButton()
  private let gridStack = NSStackView()
  var onDismiss: (() -> Void)?
  var menuForFavorite: ((TabID) -> NSMenu?)?
  var onSelectFavorite: ((TabID) -> Void)?
  private var isShowingGrid = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setup() {
    starIcon.image = NSImage(systemSymbolName: "star.circle", accessibilityDescription: "Favorites")
    starIcon.contentTintColor = .secondaryLabelColor
    titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    titleLabel.textColor = .labelColor
    subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byWordWrapping
    subtitleLabel.maximumNumberOfLines = 2

    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
    closeButton.isBordered = false
    closeButton.imagePosition = .imageOnly
    closeButton.contentTintColor = .tertiaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(closeClicked)

    gridStack.orientation = .vertical
    gridStack.spacing = 8
    gridStack.distribution = .fillEqually
    gridStack.translatesAutoresizingMaskIntoConstraints = false
    gridStack.isHidden = true

    [starIcon, titleLabel, subtitleLabel, closeButton, gridStack].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    NSLayoutConstraint.activate([
      starIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      starIcon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      starIcon.widthAnchor.constraint(equalToConstant: 16),
      starIcon.heightAnchor.constraint(equalToConstant: 16),

      titleLabel.leadingAnchor.constraint(equalTo: starIcon.trailingAnchor, constant: 8),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

      subtitleLabel.leadingAnchor.constraint(equalTo: starIcon.trailingAnchor, constant: 8),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      subtitleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
      subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      closeButton.widthAnchor.constraint(equalToConstant: 14),
      closeButton.heightAnchor.constraint(equalToConstant: 14),

      gridStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      gridStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      gridStack.topAnchor.constraint(equalTo: topAnchor),
      gridStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @objc private func closeClicked() { onDismiss?() }

  func reloadFavorites(tiles: [FavoriteTileData], icons: [TabID: NSImage?]) {
    gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if tiles.isEmpty {
      isShowingGrid = false
      starIcon.isHidden = false
      titleLabel.isHidden = false
      subtitleLabel.isHidden = false
      closeButton.isHidden = false
      gridStack.isHidden = true
      needsDisplay = true
      return
    }

    isShowingGrid = true
    starIcon.isHidden = true
    titleLabel.isHidden = true
    subtitleLabel.isHidden = true
    closeButton.isHidden = true
    gridStack.isHidden = false

    let cols = 3
    let chunked = stride(from: 0, to: min(tiles.count, 6), by: cols).map {
      Array(tiles[$0..<min($0 + cols, tiles.count)])
    }
    for chunk in chunked {
      let rowStack = NSStackView()
      rowStack.orientation = .horizontal
      rowStack.distribution = .fillEqually
      rowStack.spacing = 8
      rowStack.translatesAutoresizingMaskIntoConstraints = false
      for item in chunk {
        let icon = icons[item.id] ?? nil
        let btn = FavTileButton(item: item, icon: icon)
        btn.target = self
        btn.action = #selector(tileClicked(_:))
        btn.menuProvider = { [weak self] in self?.menuForFavorite?(item.id) }
        rowStack.addArrangedSubview(btn)
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
      }
      if chunk.count < cols {
        for _ in chunk.count..<cols {
          let dummy = NSView()
          rowStack.addArrangedSubview(dummy)
        }
      }
      gridStack.addArrangedSubview(rowStack)
    }
    needsDisplay = true
  }

  @objc private func tileClicked(_ sender: FavTileButton) {
    if let tid = sender.item?.id {
      onSelectFavorite?(tid)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !isShowingGrid else { return }
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
    let pattern: [CGFloat] = [4, 3]
    path.setLineDash(pattern, count: 2, phase: 0)
    path.lineWidth = 1.0
    NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1.0, alpha: 0.12) : NSColor(white: 0.0, alpha: 0.12)
    }.setStroke()
    path.stroke()
  }
}

// MARK: - Spaces Dock View (Ora ContainerSwitcher + NewContainerButton)

/// Arc & Ora bottom dock with extensions button on left, space indicator pills in center, and add space button on right.
final class SpacesDockView: FlippedView {
  let extButton = NSButton()
  private let stack = NSStackView()
  private let stackScrollView = NSScrollView()
  private let addButton = NSButton()
  weak var controller: BrowserWindowController?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setup() {
    extButton.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions")
    extButton.isBordered = false
    extButton.imagePosition = .imageOnly
    extButton.contentTintColor = .secondaryLabelColor
    extButton.target = self
    extButton.action = #selector(extClicked)
    extButton.toolTip = "Extensions"
    extButton.translatesAutoresizingMaskIntoConstraints = false

    stack.orientation = .horizontal
    stack.spacing = 6
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false

    stackScrollView.documentView = stack
    stackScrollView.drawsBackground = false
    stackScrollView.hasVerticalScroller = false
    stackScrollView.hasHorizontalScroller = false
    stackScrollView.translatesAutoresizingMaskIntoConstraints = false

    addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Space")
    addButton.isBordered = false
    addButton.imagePosition = .imageOnly
    addButton.contentTintColor = .secondaryLabelColor
    addButton.target = self
    addButton.action = #selector(addSpaceClicked)
    addButton.toolTip = "New Space"
    addButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(extButton)
    addSubview(stackScrollView)
    addSubview(addButton)

    let clip = stackScrollView.contentView
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      stack.topAnchor.constraint(equalTo: clip.topAnchor),
      stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
      extButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      extButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      extButton.widthAnchor.constraint(equalToConstant: 18),
      extButton.heightAnchor.constraint(equalToConstant: 18),

      stackScrollView.leadingAnchor.constraint(equalTo: extButton.trailingAnchor, constant: 8),
      stackScrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
      stackScrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
      stackScrollView.heightAnchor.constraint(equalToConstant: 28),

      addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 20),
      addButton.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  @objc private func extClicked() {
    controller?.extensionsClicked()
  }

  func reloadSpaces(spaces: [Space], active: SpaceID?) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (idx, sp) in spaces.enumerated() {
      let btn = NSButton()
      btn.title = sp.icon
      btn.font = .systemFont(ofSize: 13)
      btn.isBordered = false
      btn.tag = idx
      btn.target = self
      btn.action = #selector(spaceBtnClicked(_:))
      btn.toolTip = "\(sp.name) (\(sp.icon))"
      btn.wantsLayer = true
      let isActive = sp.id == active
      btn.alphaValue = isActive ? 1.0 : 0.6
      if isActive {
        btn.layer?.backgroundColor = cg(Self.activeBg)
        btn.layer?.cornerRadius = 6
      }
      stack.addArrangedSubview(btn)
      NSLayoutConstraint.activate([
        btn.widthAnchor.constraint(equalToConstant: 28),
        btn.heightAnchor.constraint(equalToConstant: 28),
      ])
    }
  }

  private static let activeBg = NSColor(name: nil) { a in
    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.28, alpha: 1.0) : NSColor(white: 0.82, alpha: 1.0)
  }
  override func viewDidChangeEffectiveAppearance() {
    for case let b as NSButton in stack.arrangedSubviews where b.layer?.backgroundColor != nil { b.layer?.backgroundColor = cg(Self.activeBg) }
  }

  @objc private func spaceBtnClicked(_ sender: NSButton) {
    controller?.switchSpace(index: sender.tag)
  }

  @objc private func addSpaceClicked() {
    controller?.newSpacePrompt()
  }
}

// MARK: - Command Bar (⌘T) Wireframe Views

public struct CommandBarItem: Sendable {
  public let id: String
  public let icon: NSImage?
  public let title: String
  public let isSwitchToTab: Bool
  public let tabId: TabID?
  public let spaceId: SpaceID?
  public let url: String?

  public init(id: String = UUID().uuidString, icon: NSImage? = nil, title: String, isSwitchToTab: Bool = false, tabId: TabID? = nil, spaceId: SpaceID? = nil, url: String? = nil) {
    self.id = id; self.icon = icon; self.title = title; self.isSwitchToTab = isSwitchToTab; self.tabId = tabId; self.spaceId = spaceId; self.url = url
  }
}

final class CommandBarTableRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    if isSelected {
      let rect = bounds.insetBy(dx: 6, dy: 1)
      let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
      let color = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.22, alpha: 1.0) : NSColor(white: 0.88, alpha: 1.0)
      }
      color.setFill()
      path.fill()
    }
  }
}

final class CommandBarCellView: NSTableCellView {
  let iconView = NSImageView()
  let titleLabel = NSTextField(labelWithString: "")
  let hostLabel = NSTextField(labelWithString: "")
  let switchBadge = NSTextField(labelWithString: "Switch to Tab  ↵")
  private static let badgeBg = NSColor(name: nil) { a in
    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.wantsLayer = true
    iconView.layer?.cornerRadius = 4
    iconView.layer?.masksToBounds = true

    titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    hostLabel.font = .systemFont(ofSize: 12)
    hostLabel.textColor = .tertiaryLabelColor
    hostLabel.lineBreakMode = .byTruncatingTail
    hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    switchBadge.font = .systemFont(ofSize: 11, weight: .medium)
    switchBadge.textColor = .secondaryLabelColor
    switchBadge.alignment = .center
    switchBadge.wantsLayer = true
    switchBadge.layer?.cornerRadius = 5
    switchBadge.layer?.backgroundColor = cg(Self.badgeBg)
    switchBadge.setContentHuggingPriority(.required, for: .horizontal)
    switchBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

    [iconView, titleLabel, hostLabel, switchBadge].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      hostLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
      hostLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchBadge.leadingAnchor, constant: -10),

      switchBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      switchBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
      switchBadge.heightAnchor.constraint(equalToConstant: 20),
      switchBadge.widthAnchor.constraint(equalToConstant: 98),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() { switchBadge.layer?.backgroundColor = cg(Self.badgeBg) }

  func configure(with item: CommandBarItem) {
    titleLabel.stringValue = item.title
    iconView.image = item.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    switchBadge.isHidden = !item.isSwitchToTab
    hostLabel.stringValue = item.url.flatMap { URL(string: $0)?.host } ?? ""
  }
}

final class CommandBarView: FlippedView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
  let searchIcon = NSImageView()
  let textField = NSTextField()
  let divider = SidebarDividerView()
  let table = NSTableView()
  let scrollView = NSScrollView()

  var allItems: [CommandBarItem] = []
  var filteredItems: [CommandBarItem] = []

  var onSelect: ((CommandBarItem) -> Void)?
  var onDismiss: (() -> Void)?

  private static let headerH: CGFloat = 56, rowH: CGFloat = 40, maxRows = 8
  /// The bar is only as tall as its results (the overlay activates this).
  lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 340)
  private func fitHeight() {
    let rows = min(filteredItems.count, Self.maxRows)
    heightConstraint.constant = rows == 0 ? Self.headerH : Self.headerH + 5 + CGFloat(rows) * Self.rowH + 8
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setup() {
    wantsLayer = true
    layer?.masksToBounds = false                  // the rounded card is drawn in draw(); clipping the layer would also clip its shadow

    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
    searchIcon.contentTintColor = .secondaryLabelColor

    textField.placeholderString = "Search tabs, or type a URL"
    textField.font = .systemFont(ofSize: 18, weight: .regular)
    textField.textColor = .labelColor
    textField.isBordered = false
    textField.focusRingType = .none
    textField.backgroundColor = .clear
    textField.delegate = self

    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
    table.addTableColumn(col)
    table.headerView = nil
    table.rowHeight = Self.rowH; table.intercellSpacing = .zero; table.style = .plain      // the default inset style pads the first row down
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(tableClicked)

    scrollView.documentView = table
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.scrollerStyle = .overlay
    scrollView.automaticallyAdjustsContentInsets = false       // the window extends under the titlebar; without this the first row is pushed down and clipped
    scrollView.contentInsets = NSEdgeInsetsZero

    [searchIcon, textField, divider, scrollView].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    NSLayoutConstraint.activate([
      searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      searchIcon.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerH / 2),
      searchIcon.widthAnchor.constraint(equalToConstant: 20),
      searchIcon.heightAnchor.constraint(equalToConstant: 20),

      textField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 12),
      textField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
      textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
      textField.heightAnchor.constraint(equalToConstant: 28),

      divider.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerH),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1),

      scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) {
    let bg = NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.98)
        : NSColor(white: 0.98, alpha: 0.98)
    }
    let edge = NSColor(name: nil) { a in
      a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)
    }
    let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    bg.setFill(); card.fill()
    edge.setStroke(); card.lineWidth = 1; card.stroke()
  }
  override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

  func setInitialItems(_ items: [CommandBarItem]) {
    self.allItems = items
    self.filteredItems = items
    fitHeight()
    table.reloadData()
    if !filteredItems.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    let q = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty {
      filteredItems = allItems
    } else {
      let matches = allItems.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.url?.localizedCaseInsensitiveContains(q) ?? false) }
      var results = matches
      // Default fallback row: what you typed comes first when it looks like a URL, otherwise after the matching tabs
      let isUrl = q.contains(".") && !q.contains(" ")
      let defaultTitle = isUrl ? "Open \(q)" : "Search Google for \"\(q)\""
      let defaultItem = CommandBarItem(icon: NSImage(systemSymbolName: isUrl ? "arrow.up.right.square" : "magnifyingglass", accessibilityDescription: nil), title: defaultTitle, url: q)
      if isUrl { results.insert(defaultItem, at: 0) } else { results.append(defaultItem) }
      filteredItems = results
    }
    fitHeight()
    table.reloadData()
    if !filteredItems.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.moveDown(_:)) {
      let next = min(table.selectedRow + 1, filteredItems.count - 1)
      if next >= 0 { table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false) }
      return true
    } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
      let prev = max(table.selectedRow - 1, 0)
      table.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
      return true
    } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      submitSelection()
      return true
    } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onDismiss?()
      return true
    }
    return false
  }

  @objc private func tableClicked() { submitRow(table.clickedRow) }
  private func submitSelection() { submitRow(table.selectedRow) }
  private func submitRow(_ row: Int) {
    guard row >= 0, row < filteredItems.count else { return }
    onSelect?(filteredItems[row])
  }

  // NSTableViewDataSource & Delegate
  func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let id = NSUserInterfaceItemIdentifier("CmdBarRow")
    if let r = tableView.makeView(withIdentifier: id, owner: self) as? CommandBarTableRowView { return r }
    let r = CommandBarTableRowView(); r.identifier = id; return r
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let id = NSUserInterfaceItemIdentifier("CmdBarCell")
    let cell: CommandBarCellView
    if let c = tableView.makeView(withIdentifier: id, owner: self) as? CommandBarCellView { cell = c }
    else { cell = CommandBarCellView(); cell.identifier = id }
    cell.configure(with: filteredItems[row])
    return cell
  }
}

/// Floating overlay container that darkens the background and hosts the CommandBarView.
final class CommandBarOverlayView: FlippedView {
  let commandBar = CommandBarView()
  private(set) var barTop: NSLayoutConstraint!

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
    commandBar.translatesAutoresizingMaskIntoConstraints = false
    commandBar.layer?.shadowColor = NSColor.black.cgColor
    commandBar.layer?.shadowOpacity = 0.5
    commandBar.layer?.shadowOffset = .zero
    commandBar.layer?.shadowRadius = 30
    addSubview(commandBar)
    barTop = commandBar.topAnchor.constraint(equalTo: topAnchor, constant: 120)
    let preferredWidth = commandBar.widthAnchor.constraint(equalToConstant: 620)
    preferredWidth.priority = .defaultHigh                      // yields to the 24pt side margins in a narrow window

    NSLayoutConstraint.activate([
      preferredWidth,
      commandBar.centerXAnchor.constraint(equalTo: centerXAnchor),
      barTop,
      commandBar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      commandBar.heightConstraint,

    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    let loc = convert(event.locationInWindow, from: nil)
    if !commandBar.frame.contains(loc) {
      commandBar.onDismiss?()
    }
  }
}
