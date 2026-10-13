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
var afterLoad: String? = nil; if let i = args.firstIndex(of: "--after-load"), i + 1 < args.count { afterLoad = args[i + 1] }
var flagKV: [(String, Bool)] = []; for (i, a) in args.enumerated() where a == "--flag" && i + 1 < args.count { let kv = args[i + 1].split(separator: "="); if kv.count == 2 { flagKV.append((String(kv[0]), kv[1] == "1")) } }
let probe = """
(function(){ if (window.__wb) return; const S = window.__wb = { frames: 0, t0: performance.now(), last: performance.now(), long: 0, worst: 0, errors: [], logs: [] };
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = function(cb){ return raf(function(t){ const n = performance.now(); const d = n - S.last; S.last = n; S.frames++; if (d > 50) S.long++; if (d > S.worst) S.worst = d; cb(t); }); };
  addEventListener('error', e => S.errors.push(String(e.message||e).slice(0,200)));
  addEventListener('unhandledrejection', e => S.errors.push('rejection: ' + String(e.reason).slice(0,200)));
  const ce = console.error; console.error = function(){ S.errors.push('console.error: ' + [].slice.call(arguments).join(' ').slice(0,200)); ce.apply(console, arguments); };
})();
"""
var terminated = 0, popups = 0, alerts = 0
final class D: NSObject, WKNavigationDelegate, WKUIDelegate {
  func webViewWebContentProcessDidTerminate(_ w: WKWebView) { terminated += 1 }
  func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) { decisionHandler(.allow) }
  func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { popups += 1; return nil }
  func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { alerts += 1; completionHandler() }
}
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func footprint(_ pid: pid_t) -> (mb: Double, cpu: Double) {
  var info = rusage_info_v4()
  let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
  return rc == 0 ? (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9) : (0, 0)
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
cfg.preferences.isElementFullscreenEnabled = true
func setFlag(_ key: String, _ on: Bool, prefs: WKPreferences? = nil) -> Bool {
  let prefs = prefs ?? cfg.preferences
  guard WKPreferences.responds(to: NSSelectorFromString("_features")), let list = WKPreferences.perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject], let f = list.first(where: { ($0.value(forKey: "key") as? String) == key }) else { return false }
  let sel = NSSelectorFromString("_setEnabled:forFeature:"); guard let imp = prefs.method(for: sel) else { return false }
  typealias Fn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void; unsafeBitCast(imp, to: Fn.self)(prefs, sel, on, f); return true
}
for (k, v) in flagKV { print("flag \(k)=\(v) applied=\(setFlag(k, v))") }
if safariUA { cfg.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15" }
if let i = args.firstIndex(of: "--script"), i + 1 < args.count, let src = try? String(contentsOfFile: args[i + 1], encoding: .utf8) { cfg.userContentController.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }   // e.g. scripts/fg-js.sh output
cfg.userContentController.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
let d = D(); let wv = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800), configuration: cfg); wv.navigationDelegate = d; wv.uiDelegate = d
let win = NSWindow(contentRect: wv.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = wv; win.orderFrontRegardless()
let hostile = args.contains("--hostile")
Task { @MainActor in
  if hostile {
    let t0 = Date(); wv.load(URLRequest(url: url)); var peak = 0.0, killed = false, pid: pid_t = 0
    while Date().timeIntervalSince(t0) < seconds {
      try? await Task.sleep(nanoseconds: 500_000_000)
      if pid == 0 { pid = (wv.value(forKey: "_webProcessIdentifier") as? Int32) ?? 0 }
      let mb = footprint(pid).mb; peak = max(peak, mb)
      if mb > 6000 && !killed { kill(pid, SIGKILL); killed = true }                 // safety net for this machine
    }
    let title = await withTaskGroup(of: String?.self) { g -> String? in
      g.addTask { @MainActor in (try? await wv.evaluateJavaScript("document.title")) as? String }
      g.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return nil }
      let r = await g.next() ?? nil; g.cancelAll(); return r }
    print("HOSTILE peak_mb=\(Int(peak)) end_mb=\(Int(footprint(pid).mb)) wc_terminated=\(terminated) guard_killed=\(killed) page_responsive=\(title != nil) title=\(title ?? "-") popups_blocked=\(popups) alerts=\(alerts) host_alive=true")
    exit(0)
  }
  let t0 = Date(); wv.load(URLRequest(url: url))
  try? await Task.sleep(nanoseconds: 3_000_000_000)
  let pid = (wv.value(forKey: "_webProcessIdentifier") as? Int32) ?? 0
  if let js = afterLoad { _ = try? await wv.evaluateJavaScript(js); try? await Task.sleep(nanoseconds: 4_000_000_000) }
  _ = try? await wv.evaluateJavaScript("if(window.__wb){__wb.frames=0;__wb.long=0;__wb.worst=0;__wb.t0=performance.now();__wb.last=performance.now();}")   // measure steady state, not load
  let c0 = footprint(pid).cpu; let w0 = Date()
  if let i = args.firstIndex(of: "--flip"), i + 1 < args.count {      // --flip Key=1@seconds : change a feature flag on the LIVE page and report frames before/after
    let a = args[i + 1].split(separator: "@"); let kv = a[0].split(separator: "="); let at = Double(a[1]) ?? 5
    try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
    let before = (try? await wv.evaluateJavaScript("__wb.frames")) as? Int ?? -1
    print("FLIP \(kv[0])=\(kv[1]) applied=\(setFlag(String(kv[0]), kv[1] == "1", prefs: wv.configuration.preferences)) frames_before=\(before) at=\(at)s")
  }
  try? await Task.sleep(nanoseconds: UInt64(max(seconds - 3, 1) * 1_000_000_000))
  if let js = evalJS, let r = try? await wv.evaluateJavaScript(js) { print("EVAL \(r)") }
  let f = footprint(pid)
  let s = try? await wv.evaluateJavaScript("JSON.stringify({title: document.title, url: location.href, frames: window.__wb && __wb.frames, secs: window.__wb && (performance.now() - __wb.t0)/1000, long50: window.__wb && __wb.long, worstMs: window.__wb && Math.round(__wb.worst), errors: window.__wb && __wb.errors.slice(0,8), coi: window.crossOriginIsolated, canvases: document.querySelectorAll('canvas').length})")
  let cpuPct = (f.cpu - c0) / Date().timeIntervalSince(w0) * 100
  print("RESULT \(s as? String ?? "{}") webcontent_mb=\(Int(f.mb)) cpu_pct=\(Int(cpuPct)) load_s=\(Int(Date().timeIntervalSince(t0))) ua=\(safariUA ? "safari" : "default")")
  exit(0)
}
app.run()
