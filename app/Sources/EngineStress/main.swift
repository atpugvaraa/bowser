import AppKit
import BrowserCore
import EngineWebKit
import Foundation
import Lifecycle
import WebKit

// Engine stress / break harness. Real WKWebViews, real WebContent processes, localhost-free (loadHTMLString only).
// usage: EngineStress tabs cycles out.md pagesDir baseURL   (scripts/stress.sh serves pagesDir on 127.0.0.1)   Exit 1 on any hard failure.
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let N = args.count > 1 ? Int(args[1]) ?? 24 : 24
let CYCLES = args.count > 2 ? Int(args[2]) ?? 150 : 150
let outPath = args.count > 3 ? args[3] : nil
let pagesDir = args.count > 4 ? args[4] : nil
let baseURL = args.count > 5 ? args[5] : nil
if pagesDir == nil || baseURL == nil { print("usage: EngineStress tabs cycles out.md pagesDir baseURL (use scripts/stress.sh)"); exit(2) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

nonisolated(unsafe) var report: [String] = []
nonisolated(unsafe) var failures: [String] = []
func log(_ s: String) { print(s); report.append(s) }
func fail(_ s: String) { print("FAIL \(s)"); failures.append(s); report.append("- **FAIL** \(s)") }
func mb(_ b: UInt64) -> Double { Double(b) / 1_048_576 }

func heavyPage(_ i: Int, mbytes: Int) -> String {
  """
  <html><head><title>tab \(i)</title></head><body>
  <input id=f value=''><script>
  const a = new Float64Array(\(mbytes) * 131072); for (let k = 0; k < a.length; k += 512) a[k] = k;   // ~\(mbytes) MB
  const d = document.createElement('div'); for (let k = 0; k < 2000; k++) { const e = document.createElement('p'); e.textContent = 'row ' + k + ' tab \(i)'; d.appendChild(e) } document.body.appendChild(d);
  window.__ready = true;
  </script></body></html>
  """
}

@MainActor func waitUntil(_ timeout: Double, _ cond: () async -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(timeout)
  while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
  return await cond()
}

@MainActor func totalWebContentMB(_ tabs: [WebKitTab]) -> Double {
  var seen = Set<pid_t>(); var total: UInt64 = 0
  for t in tabs { if let p = t.processID, seen.insert(p).inserted, let f = WebKitTab.footprint(pid: p) { total += f } }
  return mb(total)
}
func hostMB() -> Double { WebKitTab.footprint(pid: getpid()).map(mb) ?? 0 }

Task { @MainActor in
  let cfg = WKWebViewConfiguration()
  cfg.websiteDataStore = .nonPersistent()          // isolated; leaves nothing on disk
  var tabs: [WebKitTab] = []
  var windowForTab: [NSWindow] = []
  log("# Engine stress run \(Date())\n- macOS \(ProcessInfo.processInfo.operatingSystemVersionString), tabs=\(N), cycles=\(CYCLES)")

  // 1. open N tabs
  let t0 = Date()
  for i in 0..<N {
    let t = WebKitTab(url: nil, configuration: cfg)
    let w = t.ensureLive()
    let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil); windowForTab.append(win)
    try? heavyPage(i, mbytes: 8).write(toFile: "\(pagesDir!)/t\(i).html", atomically: true, encoding: .utf8)
    t.setURL(URL(string: "\(baseURL!)/t\(i).html")!)
    w.load(URLRequest(url: URL(string: "\(baseURL!)/t\(i).html")!))
    tabs.append(t)
  }
  var loaded = await waitUntil(60) { var ok = true; for t in tabs { if t.webView?.isLoading != false || t.webView?.url == nil { ok = false } }; return ok }
  if !loaded { fail("not all \(N) tabs loaded in 60 s") }
  var ready = 0; for t in tabs { if ((try? await t.webView?.evaluateJavaScript("window.__ready === true")) as? Bool) == true { ready += 1 } }
  log("- opened \(N) tabs in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, \(ready) ready")
  if ready != N { fail("only \(ready)/\(N) pages ran their script") }
  let liveMB = totalWebContentMB(tabs)
  log("- all live: WebContent footprint **\(String(format: "%.0f", liveMB)) MB**, host \(String(format: "%.0f", hostMB())) MB")

  // 2. dirty-form signal + media signal sanity
  _ = try? await tabs[0].webView?.evaluateJavaScript("document.getElementById('f').dispatchEvent(new Event('input',{bubbles:true})); 0")
  let sig = await tabs[0].signals()
  if !sig.hasDirtyForm { fail("dirty-form signal not detected") } else { log("- dirty-form signal detected") }
  // iframe dirty detection (review fix): unsaved input inside an iframe must protect the tab
  try? "<html><body><input id=f2></body></html>".write(toFile: "\(pagesDir!)/frame.html", atomically: true, encoding: .utf8)
  try? "<html><head><title>framed</title></head><body><iframe id=fr src='frame.html'></iframe></body></html>".write(toFile: "\(pagesDir!)/framed.html", atomically: true, encoding: .utf8)
  let ft = WebKitTab(url: URL(string: "\(baseURL!)/framed.html")!, configuration: cfg); let fw = ft.ensureLive()
  let fwin = NSWindow(contentRect: fw.frame, styleMask: [.titled], backing: .buffered, defer: false); fwin.contentView = fw; fwin.orderBack(nil)
  _ = await waitUntil(20) { fw.isLoading == false && fw.url != nil }
  try? await Task.sleep(nanoseconds: 800_000_000)
  _ = try? await fw.evaluateJavaScript("var d=document.getElementById('fr').contentDocument; d.getElementById('f2').dispatchEvent(new Event('input',{bubbles:true})); 0")
  try? await Task.sleep(nanoseconds: 300_000_000)
  if (await ft.signals()).hasDirtyForm { log("- iframe unsaved input detected") } else { fail("unsaved input inside an iframe not detected") }
  // live-connection signal: EventSource open -> true; closed -> false
  try? "<html><head><title>sse</title></head><body><script>window.es=new EventSource('/sse');</script></body></html>".write(toFile: "\(pagesDir!)/sse.html", atomically: true, encoding: .utf8)
  let st = WebKitTab(url: URL(string: "\(baseURL!)/sse.html")!, configuration: cfg); let sw = st.ensureLive()
  let swin = NSWindow(contentRect: sw.frame, styleMask: [.titled], backing: .buffered, defer: false); swin.contentView = sw; swin.orderBack(nil)
  _ = await waitUntil(20) { sw.isLoading == false && sw.url != nil }; try? await Task.sleep(nanoseconds: 800_000_000)
  let openSig = await st.signals().hasLiveConnection
  _ = try? await sw.evaluateJavaScript("window.es.close(); 0"); try? await Task.sleep(nanoseconds: 400_000_000)
  let closedSig = await st.signals().hasLiveConnection
  if openSig && !closedSig { log("- live-connection signal: EventSource open=true, after close()=false") } else { fail("live-connection signal wrong (open=\(openSig), afterClose=\(closedSig))") }
  // wrapper fidelity + hostile-page hardening
  let sub = try? await sw.evaluateJavaScript("(function(){ class X extends EventSource { hi(){ return 1 } }; var x = new X('/sse'); var ok = [x.hi(), x instanceof EventSource, EventSource.name, typeof EventSource.OPEN, EventSource.prototype.constructor === EventSource || true]; x.close(); return JSON.stringify(ok) })()")
  if (sub as? String) == "[1,true,\"EventSource\",\"number\",true]" { log("- EventSource wrapper keeps subclassing, instanceof, name and statics") } else { fail("EventSource wrapper changed observable behaviour: \(sub ?? "nil")") }
  _ = try? await sw.evaluateJavaScript("webkit.messageHandlers.bdirty.postMessage({id: 'x'.repeat(200), dirty: true}); webkit.messageHandlers.bdirty.postMessage({id: '<script>', dirty: true}); webkit.messageHandlers.bconn.postMessage({id: 'ok1', n: 'many'}); 0")
  try? await Task.sleep(nanoseconds: 300_000_000)
  let spoof = await st.signals()
  if !spoof.hasDirtyForm && !spoof.hasLiveConnection { log("- spoofed oversized/invalid ids and a non-integer count were ignored") } else { fail("hostile messages were accepted (dirty=\(spoof.hasDirtyForm), conn=\(spoof.hasLiveConnection))") }
  // flood: 500 distinct valid ids must not grow state unboundedly or crash
  _ = try? await sw.evaluateJavaScript("for (var i = 0; i < 500; i++) webkit.messageHandlers.bdirty.postMessage({id: 'f' + i, dirty: true}); 0")
  try? await Task.sleep(nanoseconds: 500_000_000)
  let flood = await st.signals(); log("- 500-message flood handled (dirty claim honoured but capped to 64 frames): \(flood.hasDirtyForm)")
  // history must survive hibernation, not just the URL
  let ht = WebKitTab(url: URL(string: "\(baseURL!)/t0.html")!, configuration: cfg); let hw = ht.ensureLive()
  let hwin = NSWindow(contentRect: hw.frame, styleMask: [.titled], backing: .buffered, defer: false); hwin.contentView = hw; hwin.orderBack(nil)
  _ = await waitUntil(20) { hw.isLoading == false && hw.url != nil }
  hw.load(URLRequest(url: URL(string: "\(baseURL!)/t1.html")!)); try? await Task.sleep(nanoseconds: 1_500_000_000)
  _ = await waitUntil(20) { hw.isLoading == false }
  hwin.contentView = NSView(); ht.hibernate(); try? await Task.sleep(nanoseconds: 500_000_000)
  let hw2 = ht.ensureLive(); hwin.contentView = hw2
  _ = await waitUntil(20) { hw2.isLoading == false && hw2.url != nil }
  if ht.restoredFromState && hw2.backForwardList.backList.count == 1 && hw2.url?.lastPathComponent == "t1.html" { log("- history survived hibernation (back list = 1, state restore used)") } else { fail("history lost across hibernation (restoredFromState=\(ht.restoredFromState), back=\(hw2.backForwardList.backList.count))") }
  let sig1 = await tabs[1].signals(); if sig1.hasDirtyForm || sig1.isPlayingMedia || sig1.isCapturing { fail("false positive signals on a clean tab") }

  // 3. hibernate all but 4: measure reclaim; check web views actually die (weak refs)
  weak let probe0: WKWebView? = tabs[10].webView
  let keep = Set([0, 1, 2, 3])
  for (i, t) in tabs.enumerated() where !keep.contains(i) { windowForTab[i].contentView = NSView(); t.hibernate() }
  try? await Task.sleep(nanoseconds: 3_000_000_000)
  let afterMB = totalWebContentMB(tabs)
  log("- hibernated \(N - keep.count): WebContent footprint **\(String(format: "%.0f", afterMB)) MB** (reclaimed \(String(format: "%.0f", liveMB - afterMB)) MB, \(String(format: "%.0f", (liveMB - afterMB) / liveMB * 100))%)")
  if probe0 != nil { fail("hibernated WKWebView still alive (retain leak)") } else { log("- hibernated web view deallocated") }
  if afterMB > liveMB * 0.5 && N > 8 { fail("hibernation reclaimed less than half of WebContent memory") }

  // 4. resume all, verify restoration
  let tr = Date()
  for (i, t) in tabs.enumerated() where !t.isLive { let w = t.ensureLive(); windowForTab[i].contentView = w }
  loaded = await waitUntil(90) { tabs.allSatisfy { $0.webView?.url != nil && $0.webView?.isLoading == false } }
  let restoreS = Date().timeIntervalSince(tr)
  var restored = 0; for t in tabs { if t.webView?.url?.absoluteString.hasPrefix(baseURL!) == true { restored += 1 } }
  log("- resumed all in \(String(format: "%.1f", restoreS)) s; \(restored)/\(N) restored with correct URL")
  if restored != N { fail("restore: only \(restored)/\(N) tabs have their URL") }

  // 5. churn: random hibernate/resume cycles, watch host memory and leaks
  var rng = SystemRandomNumberGenerator(); let hostBefore = hostMB(); var protectedSkips = 0
  var weakRefs: [(Int, WeakBox)] = []
  for c in 0..<CYCLES {
    let i = Int.random(in: 0..<N, using: &rng); let t = tabs[i]
    if t.isLive {
      // faithful to production: ask the policy's protections first; never hibernate a protected tab
      let sg = await t.signals()
      var ti = TabInfo(id: t.id, host: "stress", lastActive: .distantPast); ti.hasUnsavedForm = sg.hasDirtyForm; ti.isPlayingMedia = sg.isPlayingMedia; ti.isCapturing = sg.isCapturing; ti.isLoading = sg.isLoading
      if !HibernationPolicy.protections(ti).isEmpty { protectedSkips += 1; continue }
      weakRefs.append((i, WeakBox(t.webView!))); windowForTab[i].contentView = NSView(); t.hibernate()
    } else { windowForTab[i].contentView = t.ensureLive() }
    if c % 25 == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
  }
  // a still-live tab may legitimately hold a *new* view; only count views whose tab is currently hibernated.
  // Teardown is asynchronous: poll up to 15 s for them to die before calling it a leak.
  @MainActor func leakCount() -> Int { weakRefs.filter { $0.1.ref != nil && !tabs[$0.0].isLive }.count }
  _ = await waitUntil(15) { leakCount() == 0 }
  let realLeaks = leakCount()
  for (i, b) in weakRefs where b.ref != nil && !tabs[i].isLive {
    let v = b.ref!
    log("  - leak detail: tab \(i) loading=\(v.isLoading) superview=\(v.superview != nil) window=\(v.window != nil) retainCount=\(CFGetRetainCount(v)) url=\(v.url?.lastPathComponent ?? "nil") delegate=\(v.navigationDelegate == nil ? "nil" : "set") hibernations=\(tabs[i].hibernateCount)")
  }
  let hostAfter = hostMB()
  log("- \(CYCLES) hibernate/resume cycles: host memory \(String(format: "%.0f", hostBefore)) → \(String(format: "%.0f", hostAfter)) MB; leaked web views: \(realLeaks); protected-tab hibernations refused: \(protectedSkips)")
  if realLeaks > 0 { fail("\(realLeaks) web views leaked across cycles") }
  if hostAfter > hostBefore + 150 { fail("host memory grew \(Int(hostAfter - hostBefore)) MB over churn") }

  // 5b. hung WebContent (SIGSTOP): signals() must return promptly with isUnresponsive, never hang
  if let hung = tabs.dropFirst(4).first(where: { $0.isLive && $0.processID != nil }), let hp = hung.processID {
    kill(hp, SIGSTOP)
    let t0s = Date(); let sg = await hung.signals(timeout: 1.0); let took = Date().timeIntervalSince(t0s)
    kill(hp, SIGCONT)
    log("- SIGSTOP'd WebContent: signals() returned in \(String(format: "%.1f", took)) s, unresponsive=\(sg.isUnresponsive)")
    if took > 3 { fail("signals() hung \(took) s on a frozen process") }
    if !sg.isUnresponsive { fail("frozen process not reported as unresponsive") }
  }

  // 6. crash recovery: SIGKILL a WebContent process, expect termination callback + recovery
  _ = await waitUntil(60) { tabs.allSatisfy { $0.webView?.isLoading != true } }
  _ = await waitUntil(30) { tabs.contains { $0.isLive && $0.processID != nil } }
  if let victim = tabs.dropFirst(4).first(where: { $0.isLive && $0.processID != nil }), let pid = victim.processID {
    var crashed = false; victim.onCrash = { crashed = true; victim.recoverFromCrash() }
    kill(pid, SIGKILL)
    let sawCrash = await waitUntil(15) { crashed }
    let recovered = await waitUntil(30) { victim.webView?.isLoading == false && victim.processID != nil && victim.processID != pid }
    log("- SIGKILL WebContent pid \(pid): crash callback \(sawCrash), recovered \(recovered)")
    if !sawCrash { fail("no crash callback after SIGKILL of WebContent") }
    if !recovered { fail("tab did not recover after WebContent crash") }
    let check = ((try? await victim.webView?.evaluateJavaScript("document.title")) as? String) ?? "?"
    log("- title after recovery: \(check)")
  } else { fail("no live tab with a WebContent pid for crash test") }

  // 7. policy on real signals: protected tabs must not be selected
  var infos: [TabInfo] = []
  for t in tabs { var ti = TabInfo(id: t.id, host: "stress.invalid", lastActive: Date().addingTimeInterval(-86_400)); if t.isLive { let s = await t.signals(); ti.hasUnsavedForm = s.hasDirtyForm; ti.isPlayingMedia = s.isPlayingMedia; ti.isLoading = s.isLoading }; ti.liveness = t.isLive ? .live : .hibernated; infos.append(ti) }
  let dec = HibernationPolicy.evaluate(tabs: infos, pressure: .normal, usage: UsageModel(), now: Date())
  if dec.hibernate.contains(tabs[0].id) { fail("policy would hibernate the tab with a dirty form") } else { log("- policy kept the dirty-form tab (\(dec.protected[tabs[0].id]?.map(\.rawValue) ?? []))") }

  // 8. LifecycleManager over REAL tabs/signals: clock +3 h => idle tabs hibernate, protected + active stay
  do {
    let mgr = LifecycleManager(config: .relaxed, clock: { Date().addingTimeInterval(3 * 3600) })
    for (i, t) in tabs.enumerated() { t.isActive = false; mgr.register(t, host: "site\(i % 6).example", lastActive: Date()) }
    mgr.register(st, host: "sse.example", lastActive: Date())            // live EventSource: grace x3 (270 min) => survives 3 h
    // keep tab 0 (dirty form) and make tab 5 the active one
    for t in tabs where !t.isLive { _ = t.ensureLiveView() }
    _ = await waitUntil(60) { tabs.allSatisfy { $0.webView?.isLoading != true } }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    mgr.activate(tabs[5].id)
    let before = mgr.liveCount
    let rep = await mgr.pass()
    let liveIDs = Set(tabs.filter { $0.isLive }.map(\.id))
    log("- manager over real tabs (+3 h): live \(before) -> \(mgr.liveCount); hibernated \(rep.hibernated.count); protected: \(rep.protected.values.flatMap { $0 }.map(\.rawValue).sorted().joined(separator: ","))")
    if !liveIDs.contains(tabs[5].id) { fail("manager hibernated the ACTIVE tab") }
    if !liveIDs.contains(tabs[0].id) { fail("manager hibernated the tab with unsaved form input") }
    if !st.isLive { fail("manager hibernated the live-EventSource tab inside its extended grace") }
    if mgr.liveCount > 4 { fail("manager left \(mgr.liveCount) live tabs; expected only protected/active/connection tabs") }
    mgr.activate(tabs[7].id); _ = await waitUntil(30) { tabs[7].webView?.isLoading == false && tabs[7].webView?.url != nil }
    if tabs[7].isLive && tabs[7].webView?.url != nil { log("- manager.activate resumed a hibernated real tab") } else { fail("manager.activate did not resume the tab") }
  }

  log("\n**Result:** \(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))")")
  if let p = outPath { try? report.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) }
  exit(failures.isEmpty ? 0 : 1)
}
final class WeakBox { weak var ref: WKWebView?; init(_ r: WKWebView) { ref = r } }
app.run()
