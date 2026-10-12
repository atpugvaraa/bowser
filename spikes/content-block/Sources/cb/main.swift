import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
// Native content blocking via WKContentRuleList. usage: cb <url> [block|noblock]
let url = URL(string: CommandLine.arguments[1])!
let mode = CommandLine.arguments.dropFirst(2).first ?? "block"
let rules = """
[{"trigger":{"url-filter":"pagead2\\\\.googlesyndication\\\\.com"},"action":{"type":"block"}},
 {"trigger":{"url-filter":"securepubads\\\\.g\\\\.doubleclick\\\\.net"},"action":{"type":"block"}},
 {"trigger":{"url-filter":"googleads\\\\.g\\\\.doubleclick\\\\.net"},"action":{"type":"block"}}]
"""
final class Loader: NSObject, WKNavigationDelegate { var c: CheckedContinuation<Void, Never>?
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { c?.resume(); c = nil } }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
Task { @MainActor in
  let cfg = WKWebViewConfiguration()
  if mode == "block" {
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("cb-store-\(UUID().uuidString)")
    let store = WKContentRuleListStore(url: storeURL)!
    let t0 = Date()
    do {
      let list = try await store.compileContentRuleList(forIdentifier: "ads", encodedContentRuleList: rules)
      print("compiled in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
      cfg.userContentController.add(list!)
    } catch { print("COMPILE FAIL:", error); exit(1) }
  }
  let w = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
  let l = Loader(); w.navigationDelegate = l
  let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil)
  await withCheckedContinuation { c in l.c = c; w.load(URLRequest(url: url)) }
  try? await Task.sleep(nanoseconds: 6_000_000_000)
  let r = try? await w.evaluateJavaScript("document.documentElement.getAttribute('data-ext')")
  print("RESULT \(mode):", r ?? "nil")
  exit(0)
}
app.run()
