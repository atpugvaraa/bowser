import AppKit
import Darwin
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
// Web test harness: loads a URL in a visible WKWebView for N seconds, injects an FPS/error probe at document start,
// prints a JSON summary (fps, long frames, JS errors, WebGL/WASM info, WebContent memory + CPU). usage: wb <url> <seconds> [--safari-ua] [--eval <js>]
let args = CommandLine.arguments
let url = URL(string: args[1])!
let seconds = Double(args[2]) ?? 20
let safariUA = args.contains("--safari-ua")
var evalJS: String? = nil; if let i = args.firstIndex(of: "--eval"), i + 1 < args.count { evalJS = args[i + 1] }
let probe = """
(function(){ if (window.__wb) return; const S = window.__wb = { frames: 0, t0: performance.now(), last: performance.now(), long: 0, worst: 0, errors: [], logs: [] };
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = function(cb){ return raf(function(t){ const n = performance.now(); const d = n - S.last; S.last = n; S.frames++; if (d > 50) S.long++; if (d > S.worst) S.worst = d; cb(t); }); };
  addEventListener('error', e => S.errors.push(String(e.message||e).slice(0,200)));
  addEventListener('unhandledrejection', e => S.errors.push('rejection: ' + String(e.reason).slice(0,200)));
  const ce = console.error; console.error = function(){ S.errors.push('console.error: ' + [].slice.call(arguments).join(' ').slice(0,200)); ce.apply(console, arguments); };
})();
"""
final class D: NSObject, WKNavigationDelegate, WKUIDelegate {
  func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) { decisionHandler(.allow) }
  func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
  func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { print("ALERT:", m.prefix(100)); completionHandler() }
}
func footprint(_ pid: pid_t) -> (mb: Double, cpu: Double) {
  var info = rusage_info_v4()
  let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
  return rc == 0 ? (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_user_time + info.ri_system_time) / 1e9) : (0, 0)
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
cfg.preferences.isElementFullscreenEnabled = true
if safariUA { cfg.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15" }
cfg.userContentController.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
let d = D(); let wv = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800), configuration: cfg); wv.navigationDelegate = d; wv.uiDelegate = d
let win = NSWindow(contentRect: wv.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = wv; win.orderFrontRegardless()
Task { @MainActor in
  let t0 = Date(); wv.load(URLRequest(url: url))
  try? await Task.sleep(nanoseconds: 3_000_000_000)
  let pid = (wv.value(forKey: "_webProcessIdentifier") as? Int32) ?? 0
  let c0 = footprint(pid).cpu; let w0 = Date()
  try? await Task.sleep(nanoseconds: UInt64(max(seconds - 3, 1) * 1_000_000_000))
  if let js = evalJS { _ = try? await wv.evaluateJavaScript(js) }
  let f = footprint(pid)
  let s = try? await wv.evaluateJavaScript("JSON.stringify({title: document.title, url: location.href, frames: window.__wb && __wb.frames, secs: window.__wb && (performance.now() - __wb.t0)/1000, long50: window.__wb && __wb.long, worstMs: window.__wb && Math.round(__wb.worst), errors: window.__wb && __wb.errors.slice(0,8), coi: window.crossOriginIsolated, canvases: document.querySelectorAll('canvas').length})")
  let cpuPct = (f.cpu - c0) / Date().timeIntervalSince(w0) * 100
  print("RESULT \(s as? String ?? "{}") webcontent_mb=\(Int(f.mb)) cpu_pct=\(Int(cpuPct)) load_s=\(Int(Date().timeIntervalSince(t0))) ua=\(safariUA ? "safari" : "default")")
  exit(0)
}
app.run()
