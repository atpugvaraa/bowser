import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
let mode = CommandLine.arguments.dropFirst().first ?? "orderOut"   // orderOut | detach | hiddenView | visible
let url = URL(string: CommandLine.arguments[2])!
final class Loader: NSObject, WKNavigationDelegate { var c: CheckedContinuation<Void, Never>?
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { c?.resume(); c = nil } }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
Task { @MainActor in
  let cfg = WKWebViewConfiguration(); cfg.mediaTypesRequiringUserActionForPlayback = []
  let wv = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
  let l = Loader(); wv.navigationDelegate = l
  let win = NSWindow(contentRect: wv.frame, styleMask: [.titled], backing: .buffered, defer: false)
  win.contentView = wv; win.orderFront(nil)
  await withCheckedContinuation { c in l.c = c; wv.load(URLRequest(url: url)) }
  func st() async -> String { ((try? await wv.evaluateJavaScript("state()")) as? String) ?? "?" }
  print("start:", (try? await wv.evaluateJavaScript("start()")) ?? "nil")
  try? await Task.sleep(nanoseconds: 3_000_000_000)
  print("visible   :", await st())
  switch mode {
  case "orderOut": win.orderOut(nil)
  case "detach": wv.removeFromSuperview()
  case "hiddenView": wv.isHidden = true
  default: break
  }
  try? await Task.sleep(nanoseconds: 6_000_000_000)
  print("after \(mode):", await st())
  exit(0)
}
app.run()
