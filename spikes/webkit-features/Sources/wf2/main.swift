import AppKit
import Darwin
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
// Feature-flag cost experiment. usage: wf2 <label> <base-url> [flag=on|off ...]
let label = CommandLine.arguments[1], base = CommandLine.arguments[2]
let flags = CommandLine.arguments.dropFirst(3).map { $0.split(separator: "=").map(String.init) }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
func footprint(_ pid: pid_t) -> Double {
  var info = rusage_info_v4()
  let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
  return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
}
final class Loader: NSObject, WKNavigationDelegate { var c: CheckedContinuation<Void, Never>?
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { c?.resume(); c = nil }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { c?.resume(); c = nil } }
Task { @MainActor in
  let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID())
  func setFeature(_ key: String, _ on: Bool) {
    guard let list = WKPreferences.perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject],
          let f = list.first(where: { ($0.value(forKey: "key") as? String) == key }) else { print("no such feature \(key)"); return }
    let sel = NSSelectorFromString("_setEnabled:forFeature:")
    typealias Fn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    unsafeBitCast(cfg.preferences.method(for: sel), to: Fn.self)(cfg.preferences, sel, on, f)
  }
  for f in flags where f.count == 2 { setFeature(f[0], f[1] == "on") }
  let n = 8, hops = 5
  var views: [WKWebView] = [], loaders: [Loader] = [], wins: [NSWindow] = []
  for _ in 0..<n {
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 400), configuration: cfg); let l = Loader(); w.navigationDelegate = l
    let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil)
    views.append(w); loaders.append(l); wins.append(win)
  }
  for hop in 0..<hops {
    for i in 0..<n { await withCheckedContinuation { c in loaders[i].c = c; views[i].load(URLRequest(url: URL(string: "\(base)/p\((hop + i) % 6).html")!)) } }
  }
  try? await Task.sleep(nanoseconds: 4_000_000_000)
  var pids = Set<pid_t>(); for v in views { if let p = v.value(forKey: "_webProcessIdentifier") as? Int32, p > 0 { pids.insert(p) } }
  let mem = pids.reduce(0.0) { $0 + footprint($1) }
  // back navigation latency (bfcache hit = fast)
  var backMs: [Double] = []
  for i in 0..<n { let t = Date(); await withCheckedContinuation { c in loaders[i].c = c; views[i].goBack() }; backMs.append(Date().timeIntervalSince(t) * 1000) }
  let avgBack = backMs.reduce(0, +) / Double(backMs.count)
  print("RESULT \(label): webcontent_mb=\(String(format: "%.0f", mem)) procs=\(pids.count) avg_back_ms=\(String(format: "%.0f", avgBack)) flags=\(flags.map { $0.joined(separator: "=") })")
  exit(0)
}
app.run()
