import AppKit
import CoreImage.CIFilterBuiltins
import EngineWebKit
import Hybrid

/// The "Use your iPhone" sheet: shows the QR code, relays the status, cancels the transaction. One at a time.
@MainActor
final class PasskeyUI: NSObject {
  unowned let app: AppDelegate
  private var panel: NSPanel?
  private let qrView = NSImageView(), status = NSTextField(wrappingLabelWithString: "Preparing…"), title = NSTextField(labelWithString: "")
  private var current: Task<Data, Error>?

  init(app: AppDelegate) { self.app = app; super.init() }

  func perform(kind: String, rpId: String, origin: String, ctap: Data) async throws -> Data {
    let scanner = BLEAdvertSource()
    scanner.onProblem = { [weak self] m in Task { @MainActor in self?.status.stringValue = m } }
    let client = HybridClient(scanner: scanner) { try await WebSocketTunnel.connect($0) }
    show(kind: kind, rpId: rpId)
    defer { hide() }
    let flow = kind == "create" ? "mc" : "ga"
    let onQR: @Sendable (String) -> Void = { [weak self] qr in Task { @MainActor in self?.qrView.image = Self.qrImage(qr) } }
    let onStatus: @Sendable (String) -> Void = { [weak self] s in Task { @MainActor in self?.status.stringValue = s } }
    let task = Task<Data, Error> { try await client.run(flow: flow, ctapRequest: ctap, onQR: onQR, onStatus: onStatus) }
    current = task
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
  func cancel() { current?.cancel() }

  private func show(kind: String, rpId: String) {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
    p.isReleasedWhenClosed = false
    title.stringValue = kind == "create" ? "Create a passkey for \(rpId)" : "Sign in to \(rpId)"
    title.font = .boldSystemFont(ofSize: 14); title.alignment = .center
    qrView.imageScaling = .scaleProportionallyUpOrDown; qrView.image = nil
    status.stringValue = "Preparing…"; status.alignment = .center; status.font = .systemFont(ofSize: 12)
    let hint = NSTextField(wrappingLabelWithString: "Point your iPhone camera at the code. Your passkey stays on the phone; approve with Face ID there.")
    hint.alignment = .center; hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\u{1b}"
    let stack = NSStackView(views: [title, qrView, status, hint, cancel]); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    qrView.widthAnchor.constraint(equalToConstant: 260).isActive = true; qrView.heightAnchor.constraint(equalToConstant: 260).isActive = true
    hint.widthAnchor.constraint(equalToConstant: 290).isActive = true; status.widthAnchor.constraint(equalToConstant: 290).isActive = true
    p.contentView = stack; p.setContentSize(stack.fittingSize)
    panel = p
    if let w = app.keyController?.window { w.beginSheet(p, completionHandler: nil) } else { p.center(); p.makeKeyAndOrderFront(nil) }
  }
  private func hide() {
    guard let p = panel else { return }
    if let parent = p.sheetParent { parent.endSheet(p) } else { p.orderOut(nil) }
    panel = nil; current = nil
  }
  @objc private func cancelClicked() { cancel() }

  static func qrImage(_ text: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator(); f.message = Data(text.utf8); f.correctionLevel = "M"
    guard let out = f.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: out); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
  }
}
