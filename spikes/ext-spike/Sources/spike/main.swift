import AppKit
setvbuf(stdout, nil, _IONBF, 0)
import WebKit

let extDir = URL(fileURLWithPath: CommandLine.arguments[1])
let url = URL(string: CommandLine.arguments[2])!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
  do {
    let ext = try await WKWebExtension(resourceBaseURL: extDir)
    print("manifest v\(ext.manifestVersion) name=\(ext.displayName ?? "?") errors=\(ext.errors.count)")
    let ctx = WKWebExtensionContext(for: ext)
    ctx.setPermissionStatus(.grantedExplicitly, for: url)
    for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
    for m in ext.allRequestedMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
    let ctl = WKWebExtensionController()
    let cfg = WKWebViewConfiguration()
    cfg.webExtensionController = ctl
    try ctl.load(ctx)
    try? await Task.sleep(nanoseconds: 1_500_000_000) // let background worker start
    let wv = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 400), configuration: cfg)
    let win = NSWindow(contentRect: wv.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = wv; win.orderFront(nil)
    wv.load(URLRequest(url: url))
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let r = try await wv.evaluateJavaScript("document.documentElement.getAttribute('data-ext') + ' | ' + document.documentElement.getAttribute('data-bg')")
    print("RESULT:", r ?? "nil")
    print("ctx errors:", ctx.errors.map(\.localizedDescription))
  } catch { print("FAIL:", error) }
  exit(0)
}
app.run()
