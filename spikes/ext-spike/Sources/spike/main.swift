import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)

// Minimal tab/window model implementing the extension protocols (the product's tab model must do this too).
final class SpikeTab: NSObject, WKWebExtensionTab {
  let webView: WKWebView; weak var win: SpikeWindow?
  init(_ wv: WKWebView) { webView = wv }
  func webView(for c: WKWebExtensionContext) -> WKWebView? { webView }
  func window(for c: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { win }
  func url(for c: WKWebExtensionContext) -> URL? { webView.url }
  func title(for c: WKWebExtensionContext) -> String? { webView.title }
  func isSelected(for c: WKWebExtensionContext) -> Bool { true }
  func isLoadingComplete(for c: WKWebExtensionContext) -> Bool { !webView.isLoading }
  func indexInWindow(for c: WKWebExtensionContext) -> Int { 0 }
}
final class SpikeWindow: NSObject, WKWebExtensionWindow {
  var tab: SpikeTab!
  func tabs(for c: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
  func activeTab(for c: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
  func windowType(for c: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
  func windowState(for c: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
  func isPrivate(for c: WKWebExtensionContext) -> Bool { false }
}
final class Host: NSObject, WKWebExtensionControllerDelegate {
  var window: SpikeWindow!
  func webExtensionController(_ c: WKWebExtensionController, openWindowsFor ctx: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [window] }
  func webExtensionController(_ c: WKWebExtensionController, focusedWindowFor ctx: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }
}

let extDir = URL(fileURLWithPath: CommandLine.arguments[1])
let url = URL(string: CommandLine.arguments[2])!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
  do {
    let ext = try await WKWebExtension(resourceBaseURL: extDir)
    print("manifest v\(ext.manifestVersion) name=\(ext.displayName ?? "?") errors=\(ext.errors.count)")
    let ctx = WKWebExtensionContext(for: ext)
    // spike policy: grant only what the manifest declares (product: user prompt)
    ctx.setPermissionStatus(.grantedExplicitly, for: url)
    for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
    for m in ext.requestedPermissionMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
    let ctl = WKWebExtensionController(); let host = Host(); ctl.delegate = host
    let cfg = WKWebViewConfiguration(); cfg.webExtensionController = ctl
    let wv = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 400), configuration: cfg)
    let w = SpikeWindow(), t = SpikeTab(wv); t.win = w; w.tab = t; host.window = w
    let win = NSWindow(contentRect: wv.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = wv; win.orderFront(nil)
    try ctl.load(ctx)
    ctl.didOpenWindow(w); ctl.didFocusWindow(w); ctl.didOpenTab(t); ctl.didActivateTab(t, previousActiveTab: nil)
    do { try await ctx.loadBackgroundContent(); print("background loaded") } catch { print("background load error:", error) }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    wv.load(URLRequest(url: url))
    try? await Task.sleep(nanoseconds: 8_000_000_000)
    let r = try await wv.evaluateJavaScript("document.documentElement.getAttribute('data-ext') + ' | ' + document.documentElement.getAttribute('data-bg')")
    print("RESULT:", r ?? "nil")
    print("loaded=\(ctx.isLoaded) allURLs=\(ctx.hasAccessToAllURLs) denied=\(ctx.deniedPermissions.keys.map { String(describing: $0) }.sorted()) injected=\(ctx.hasInjectedContent) cmrules=\(ctx.hasContentModificationRules) perms=\(ctx.currentPermissions.map{String(describing:$0)}.sorted())")
    print("ctx errors:", ctx.errors.map(\.localizedDescription))
  } catch { print("FAIL:", error) }
  exit(0)
}
app.run()
