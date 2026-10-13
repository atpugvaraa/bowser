import AppKit
import BrowserCore
import ContentBlocking
import EngineCore
import EngineWebKit
import Extensions
import Hybrid
import Persistence
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

  // 9. FULL ENGINE on real web views: BrowserEngine + WebKitTabFactory + SessionManager, incl. an app restart from the database
  do {
    let dbp = "\(pagesDir!)/engine-\(UUID().uuidString).sqlite"
    let (sess, st0, _) = try SessionManager.start(path: dbp, debounce: 0.1)
    let fac = WebKitTabFactory(persistent: false)
    let eng = BrowserEngine(session: sess, state: st0, factory: fac)
    let prof = ProfileID(); let sp = eng.addSpace(name: "Eng", profile: prof)
    let win = eng.openWindow(space: sp)!
    let e0 = eng.newTab(in: sp, url: "\(baseURL!)/t0.html", window: win)!
    let e1 = eng.newTab(in: sp, url: "\(baseURL!)/t1.html")!
    // give e0 a two-entry history in a real web view
    let wk0 = eng.tab(e0) as! WebKitTab
    _ = await waitUntil(30) { wk0.webView?.isLoading == false && wk0.webView?.url != nil }
    wk0.webView!.load(URLRequest(url: URL(string: "\(baseURL!)/t2.html")!)); try? await Task.sleep(nanoseconds: 800_000_000)
    _ = await waitUntil(30) { wk0.webView?.isLoading == false && wk0.webView?.url?.lastPathComponent == "t2.html" }
    log("- engine: live tabs \(eng.liveCount) of \(eng.state.tabs.count) (only the window-selected one is live)")
    if eng.liveCount != 1 { fail("engine launch laziness: \(eng.liveCount) live, expected 1") }
    // close -> archive -> restore: history must come back in a NEW web view
    eng.closeTab(e0)
    if eng.tab(e0) != nil || !eng.state.archive.contains(where: { $0.id == e0 }) { fail("closed tab not archived/torn down") }
    _ = eng.restoreTab(e0)
    let wkR = eng.tab(e0) as! WebKitTab; wkR.ensureLive()
    _ = await waitUntil(30) { wkR.webView?.isLoading == false && wkR.webView?.url != nil }
    if wkR.webView?.backForwardList.backList.count == 1 && wkR.restoredFromState { log("- engine: close -> archive -> restore kept the tab's history (back list = 1)") } else { fail("restore lost history (back=\(wkR.webView?.backForwardList.backList.count ?? -1), restoredFromState=\(wkR.restoredFromState))") }
    _ = e1
    // app restart: shut down, reopen the database in a fresh engine with a fresh factory
    try eng.shutdown()
    let (sess2, st2, rec2) = try SessionManager.start(path: dbp)
    let eng2 = BrowserEngine(session: sess2, state: st2, factory: WebKitTabFactory(persistent: false))
    let live2 = eng2.state.windows.values.compactMap(\.selected)
    log("- engine restart: recovery=\(rec2), \(eng2.state.tabs.count) tabs, live \(eng2.liveCount) (lazy)")
    if eng2.liveCount != live2.count { fail("restart not lazy: \(eng2.liveCount) live vs \(live2.count) selected") }
    // the window moved to the neighbouring tab when e0 was closed; bring e0 back into view like a user would
    let win2 = eng2.state.windows.keys.first!
    _ = eng2.select(tab: e0, in: win2)
    if let wk = eng2.tab(e0) as? WebKitTab {
      _ = await waitUntil(30) { wk.webView?.isLoading == false && wk.webView?.url != nil }
      if wk.webView?.backForwardList.backList.count == 1 && wk.restoredFromState { log("- engine restart: history survived an APP RESTART from the database (back list = 1)") } else { fail("history lost across app restart (back=\(wk.webView?.backForwardList.backList.count ?? -1))") }
    } else { fail("tab e0 missing after restart") }
  } catch { fail("full-engine integration threw: \(error)") }

  // 10. Native content blocking on real pages (local only): block, allowlist exception, merge validation
  do {
    try? FileManager.default.createDirectory(atPath: "\(pagesDir!)/ads", withIntermediateDirectories: true)
    try? "window.adLoaded = (window.adLoaded||0) + 1;".write(toFile: "\(pagesDir!)/ads/x.js", atomically: true, encoding: .utf8)
    try? "<html><head><title>adpage</title></head><body><script src='/ads/x.js'></script></body></html>".write(toFile: "\(pagesDir!)/adpage.html", atomically: true, encoding: .utf8)
    let cb = try ContentBlocker(storeURL: URL(fileURLWithPath: "\(pagesDir!)/cb-store-\(UUID().uuidString)"))
    let rules = #"[{"trigger":{"url-filter":"/ads/"},"action":{"type":"block"}}]"#
    @MainActor func adLoaded(_ cfgx: WKWebViewConfiguration, host: String) async -> Bool {
      let w = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 200), configuration: cfgx)
      let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil)
      w.load(URLRequest(url: URL(string: "http://\(host):\(URL(string: baseURL!)!.port!)/adpage.html")!))
      _ = await waitUntil(20) { w.isLoading == false && w.url != nil }; try? await Task.sleep(nanoseconds: 600_000_000)
      return ((try? await w.evaluateJavaScript("window.adLoaded === 1")) as? Bool) ?? false
    }
    let plain = WKWebViewConfiguration(); plain.websiteDataStore = .nonPersistent()
    let blocked = WKWebViewConfiguration(); blocked.websiteDataStore = .nonPersistent()
    let n = try await cb.install(id: "ads", blockRules: rules, on: blocked)
    let allow = WKWebViewConfiguration(); allow.websiteDataStore = .nonPersistent()
    _ = try await cb.install(id: "ads", blockRules: rules, allowlistDomains: ["127.0.0.1"], on: allow)
    let a = await adLoaded(plain, host: "127.0.0.1"), b = await adLoaded(blocked, host: "127.0.0.1"), c = await adLoaded(allow, host: "127.0.0.1")
    log("- content blocking (\(n) rule): without blocker ad loaded=\(a); with blocker loaded=\(b); with allowlist for the site loaded=\(c)")
    if !a { fail("test page's ad script did not load without a blocker (test invalid)") }
    if b { fail("content blocker did not block the ad request") }
    if !c { fail("allowlist exception did not re-enable the site") }
    do { _ = try ContentBlocker.merge(blockRules: "not json", allowlistDomains: []); fail("invalid rule JSON accepted") } catch { log("- content blocking rejects invalid rule JSON") }
    let merged = try ContentBlocker.merge(blockRules: rules, allowlistDomains: ["ok.example", "bad;domain", "*.evil", ""])
    if merged.contains("bad;domain") || merged.contains("*.evil") || !merged.contains("*ok.example") { fail("allowlist input not sanitised: \(merged)") } else { log("- allowlist input is sanitised (no wildcard/metacharacter injection)") }
  } catch { fail("content blocking integration threw: \(error)") }

  // 0. delegate conformance (silent-misnaming guard)
  do { let m = WebKitTab.missingDelegateMethods(); if m.isEmpty { log("- all WebKit delegate methods are implemented under their real protocol names") } else { fail("delegate methods NOT implemented (misnamed?): \(m)") } }

  // 10b. Frame governor (LTPO-style): rAF semantics preserved; full rate while interacting, slower when idle
  do {
    let g = FrameGovernor(maxHz: 120, settleMs: 300, idleMs: 600)
    let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent()
    c.userContentController.addUserScript(WKUserScript(source: g.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 200), configuration: c)
    let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.isReleasedWhenClosed = false; win.contentView = w; win.orderFrontRegardless()
    w.loadHTMLString("<html><body>fg</body></html>", baseURL: nil)
    _ = await waitUntil(20) { w.isLoading == false }
    let js = """
    const order = [];
    await new Promise(res => { requestAnimationFrame(() => { order.push('a'); requestAnimationFrame(() => { order.push('c'); res(); }); });
      const id = requestAnimationFrame(() => order.push('X')); requestAnimationFrame(() => order.push('b')); cancelAnimationFrame(id); });
    const count = async (ms, active) => { let n = 0, stop = false; const loop = () => { n++; if (!stop) requestAnimationFrame(loop); }; requestAnimationFrame(loop);
      const t = active ? setInterval(() => window.dispatchEvent(new Event('pointermove')), 40) : 0;
      await new Promise(r => setTimeout(r, ms)); stop = true; clearInterval(t); return n * 1000 / ms; };
    const active = await count(1000, true);
    await new Promise(r => setTimeout(r, 1500));
    const idle = await count(1000, false);
    const hit = []; await new Promise(res => { let idB; requestAnimationFrame(() => { hit.push('A'); cancelAnimationFrame(idB); });
      idB = requestAnimationFrame(() => hit.push('B')); requestAnimationFrame(() => res()); });
    return JSON.stringify({ order: order.join(''), active, idle, cancelInFrame: hit.join('') });
    """
    let r = try? await w.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    let m = ((r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] ?? [:]
    let act = (m["active"] as? Double) ?? -1, idl = (m["idle"] as? Double) ?? -1
    log("- frame governor: order=\(m["order"] ?? "?") active=\(Int(act)) fps idle=\(Int(idl)) fps")
    if (m["cancelInFrame"] as? String) != "A" { fail("frame governor: a cancel issued inside a frame did not stop the later callback: \(m["cancelInFrame"] ?? "nil")") }
    if (m["order"] as? String) != "abc" { fail("frame governor changed requestAnimationFrame ordering/cancel semantics: \(m["order"] ?? "nil")") }
    if act < 40 { fail("frame governor: interacting page ran at only \(Int(act)) fps") }
    if !(idl >= 10 && idl <= 45 && act > idl * 1.5) { fail("frame governor: idle page did not slow down (active \(Int(act)), idle \(Int(idl)))") }
    win.close()
    func cl(_ d: Int, _ ac: Bool, _ pct: Int?, _ lpm: Bool) -> Int { FrameGovernor.ceiling(displayMax: d, onAC: ac, batteryPercent: pct, lowPowerMode: lpm) }
    if !(cl(120, true, 80, false) == 120 && cl(120, false, 80, false) == 60 && cl(120, false, 20, false) == 30 && cl(120, true, 100, true) == 30 && cl(60, true, nil, false) == 60 && cl(120, false, nil, false) == 60) { fail("frame governor: power ceilings wrong") }
  }

  // 10c. Extension engine: a Chrome MV3 extension and a Firefox MV2 (.xpi) extension run end to end; ungranted host access is not given
  do {
    @MainActor final class Env: ExtensionEnvironment {
      let win = WindowID(); var tab: WebKitTab?
      func windowIDs() -> [WindowID] { [win] }
      func focusedWindow() -> WindowID? { win }
      func tabs(in window: WindowID) -> [WebKitTab] { tab.map { [$0] } ?? [] }
      func selectedTab(in window: WindowID) -> WebKitTab? { tab }
      func window(of tab: TabID) -> WindowID? { win }
      func openTab(url: URL?, active: Bool, in window: WindowID?) -> WebKitTab? { nil }
      func select(_ tab: TabID) {}
      func close(_ tab: TabID) {}
      var prof = ProfileID()
      func profile(ofWindow window: WindowID) -> ProfileID? { prof }
    }
    let fm = FileManager.default
    let base = URL(fileURLWithPath: "\(pagesDir!)/ext-\(UUID().uuidString)", isDirectory: true)
    func mk(_ name: String, _ files: [String: String]) throws -> URL {
      let d = base.appendingPathComponent(name, isDirectory: true); try fm.createDirectory(at: d, withIntermediateDirectories: true)
      for (k, v) in files { try v.write(to: d.appendingPathComponent(k), atomically: true, encoding: .utf8) }
      return d
    }
    let csMatch = #""content_scripts":[{"matches":["*://127.0.0.1/*"],"js":["cs.js"],"run_at":"document_idle"}]"#
    let cr = try mk("cr", ["manifest.json": #"{"manifest_version":3,"name":"CrTest","version":"1","permissions":["storage"],"host_permissions":["<all_urls>"],"background":{"service_worker":"bg.js"},\#(csMatch)}"#,
      "bg.js": "chrome.runtime.onMessage.addListener((m, s, send) => { chrome.storage.local.set({ k: m.v }).then(() => send({ ok: true, echo: m.v + 1 })); return true; });",
      "cs.js": "document.documentElement.setAttribute('data-cr0', '1'); chrome.runtime.sendMessage({ v: 41 }).then(r => document.documentElement.setAttribute('data-cr', String(r && r.echo)));"])
    let ffDir = try mk("ff", ["manifest.json": #"{"manifest_version":2,"name":"FfTest","version":"1","browser_specific_settings":{"gecko":{"id":"fftest@example.org"}},"permissions":["storage","*://127.0.0.1/*"],"background":{"scripts":["bg.js"],"persistent":true},\#(csMatch)}"#,
      "bg.js": "browser.runtime.onMessage.addListener(m => browser.storage.local.set({ k: m.v }).then(() => ({ ok: true, echo: m.v * 2 })));",
      "cs.js": "browser.runtime.sendMessage({ v: 21 }).then(r => document.documentElement.setAttribute('data-ff', String(r && r.echo)));"])
    let zp = Process(); zp.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zp.currentDirectoryURL = ffDir; zp.arguments = ["-q", "-r", base.appendingPathComponent("ff.xpi").path, "."]
    zp.standardOutput = FileHandle.nullDevice; try zp.run(); zp.waitUntilExit()
    let nogrant = try mk("ng", ["manifest.json": #"{"manifest_version":3,"name":"NoGrant","version":"1","host_permissions":["*://127.0.0.1/*"],\#(csMatch)}"#,
      "cs.js": "document.documentElement.setAttribute('data-ng', 'ran');"])
    let dnr = try mk("dnr", ["manifest.json": #"{"manifest_version":3,"name":"DnrTest","version":"1","description":"d","permissions":["declarativeNetRequest"],"host_permissions":["*://127.0.0.1/*"],"declarative_net_request":{"rule_resources":[{"id":"r1","enabled":true,"path":"rules.json"}]}}"#,
      "rules.json": #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"blockme","resourceTypes":["xmlhttprequest","script","image","other"]}}]"#])
    try "x".write(toFile: "\(pagesDir!)/blockme.txt", atomically: true, encoding: .utf8); try "x".write(toFile: "\(pagesDir!)/allowed.txt", atomically: true, encoding: .utf8)
    try "<html><head><title>exttest</title></head><body>hi</body></html>".write(toFile: "\(pagesDir!)/exttest.html", atomically: true, encoding: .utf8)
    let root = base.appendingPathComponent("installed", isDirectory: true)
    let host = ExtensionHost(registry: base.appendingPathComponent("extensions.json")); host.persistent = false; host.allowPrivate = true
    let factory = WebKitTabFactory(persistent: false); factory.extensionHost = host
    let env = Env(); host.environment = env
    let profile = env.prof
    _ = factory.configuration(for: profile)                                   // creates the profile's controller first, so installs load into it
    let pCr = try ExtensionPackage.prepare(source: cr, into: root), pFf = try ExtensionPackage.prepare(source: base.appendingPathComponent("ff.xpi"), into: root), pNg = try ExtensionPackage.prepare(source: nogrant, into: root)
    await host.install(pCr, permissions: ["storage"], hosts: pCr.hostPatterns)
    await host.install(pFf, permissions: ["storage"], hosts: ["*://127.0.0.1/*"])
    await host.install(pNg, permissions: [], hosts: [])
    let pDnr = try ExtensionPackage.prepare(source: dnr, into: root); await host.install(pDnr, permissions: ["declarativeNetRequest"], hosts: pDnr.hostPatterns)
    let t = factory.makeTab(id: TabID(), url: nil, profile: profile, restoredState: nil) as! WebKitTab
    env.tab = t; let w = t.ensureLive()
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false); win.isReleasedWhenClosed = false; win.contentView = w; win.orderFrontRegardless()
    host.didOpen(window: env.win, profile: profile); host.didFocus(window: env.win, profile: profile); host.didOpen(t, profile: profile); t.isActive = true; host.didActivate(t, previous: nil, profile: profile)
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    w.load(URLRequest(url: URL(string: "\(baseURL!)/exttest.html")!))
    var attrs: [String: Any] = [:]
    for _ in 0..<30 {
      try? await Task.sleep(nanoseconds: 500_000_000)
      let r = try? await w.evaluateJavaScript("JSON.stringify({cr: document.documentElement.getAttribute('data-cr'), ff: document.documentElement.getAttribute('data-ff'), ng: document.documentElement.getAttribute('data-ng'), cr0: document.documentElement.getAttribute('data-cr0'), loc: location.href, rs: document.readyState})")
      attrs = ((r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
      if attrs["cr"] is String && attrs["ff"] is String { break }
    }
    for l in host.status() { log("  - \(l)") }
    let net = (try? await w.callAsyncJavaScript("const t=async u=>{try{await fetch(u,{cache:'no-store'});return 'loaded'}catch(e){return 'BLOCKED'}};return (await t('/allowed.txt'))+','+(await t('/blockme.txt'))", arguments: [:], in: nil, contentWorld: .page)) as? String ?? "?"
    log("  - network rules (declarativeNetRequest static ruleset): allowed.txt,blockme.txt = \(net)")
    if net != "loaded,BLOCKED" { fail("extensions: a static declarativeNetRequest block rule did not block (\(net))") }
    log("  - page: \(attrs)")
    log("- extensions: chrome=\(attrs["cr"] ?? "nil") firefox=\(attrs["ff"] ?? "nil") ungranted=\(attrs["ng"] ?? "nil") errors=\(host.loadErrors)")
    if (attrs["cr"] as? String) != "42" { fail("extensions: Chrome MV3 content script -> service worker round trip failed (\(attrs["cr"] ?? "nil"))") }
    if (attrs["ff"] as? String) != "42" { fail("extensions: Firefox MV2 browser.* promise round trip failed (\(attrs["ff"] ?? "nil"))") }
    if attrs["ng"] is String { fail("extensions: an extension without granted host access still injected its content script") }
    if !host.loadErrors.isEmpty { fail("extensions: load errors \(host.loadErrors)") }
    // a blocked site: granted extensions get nothing there, whatever they were approved for
    host.blockedSites = ["127.0.0.1"]; try? await Task.sleep(nanoseconds: 1_000_000_000)
    w.load(URLRequest(url: URL(string: "\(baseURL!)/exttest.html?blocked")!)); try? await Task.sleep(nanoseconds: 5_000_000_000)
    let blockedAttrs = (try? await w.evaluateJavaScript("[document.documentElement.getAttribute('data-cr0'), document.documentElement.getAttribute('data-cr'), document.documentElement.getAttribute('data-ff')].join(',') + '|' + document.readyState + '|' + location.search")) as? String ?? "?"
    log("- extensions on a blocked site: \(blockedAttrs)")
    if blockedAttrs != ",,|complete|?blocked" { fail("extensions: the blocked-sites list did not stop a granted extension (\(blockedAttrs))") }
    win.close()
  } catch { fail("extensions: \(error)") }

  // 10d. Phone passkeys through a real page: navigator.credentials.create/get -> shim -> native bridge -> hybrid client -> simulated phone
  do {
    let hub = LoopbackHub(), ble = SimulatedBLE(), auth = SoftwareAuthenticator()
    let phone = SimulatedPhone(authenticator: auth, hub: hub, ble: ble)
    let factory = WebKitTabFactory(persistent: false); factory.passkeys.requireUserActivation = false      // the harness cannot produce a real click
    nonisolated(unsafe) var seenOrigins: [String] = []
    factory.passkeys.performer = { kind, rp, origin, ctap in
      seenOrigins.append(origin + "|" + rp)
      let client = HybridClient(scanner: ble, timeout: 20, connect: { try await hub.connect($0) })
      return try await client.run(flow: kind == "create" ? "mc" : "ga", ctapRequest: ctap, onQR: { qr in Task { try? await phone.scan(qr) } })
    }
    let t = factory.makeTab(id: TabID(), url: nil, profile: ProfileID(), restoredState: nil) as! WebKitTab
    let w = t.ensureLive()
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false); win.isReleasedWhenClosed = false; win.contentView = w; NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
    let port = URL(string: baseURL!)!.port!
    w.load(URLRequest(url: URL(string: "http://localhost:\(port)/exttest.html")!))
    _ = await waitUntil(20) { w.isLoading == false && w.url != nil }; try? await Task.sleep(nanoseconds: 800_000_000)
    let js = """
    const out = {};
    try {
    out.ua = navigator.userAgent; out.secure = isSecureContext; out.hasPKC = typeof PublicKeyCredential;
    out.uvpaa = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    const gap = () => new Promise(r => setTimeout(r, 3300));
    const hex = b => [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join('');
    const c = await navigator.credentials.create({ publicKey: { challenge: new Uint8Array(32).fill(1), rp: { name: 'T' }, user: { id: new Uint8Array([1, 2]), name: 'kd', displayName: 'KD' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }], authenticatorSelection: { residentKey: 'required' } } });
    out.created = { type: c.type, inst: c instanceof PublicKeyCredential, transports: c.response.getTransports(), alg: c.response.getPublicKeyAlgorithm(), pk: c.response.getPublicKey().byteLength, idMatchesRaw: c.id.length > 20 };
    const cd = JSON.parse(new TextDecoder().decode(c.response.clientDataJSON)); out.cd = cd;
    await gap();
    const g = await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32).fill(2), userVerification: 'preferred' } });
    out.got = { same: g.id === c.id, sig: g.response.signature.byteLength > 60, uh: new Uint8Array(g.response.userHandle).join(','), type: g.type };
    const ad = g.response.authenticatorData; const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('localhost'));
    out.rpHashOK = hex(ad.slice(0, 32)) === hex(h);
    out.json = typeof g.toJSON().response.signature;
    await gap();
    try { await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32), rpId: 'example.com' } }); out.badRp = 'ALLOWED'; } catch (e) { out.badRp = e.name; out.badRpMsg = e.message; }
    await gap();
    try { await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32).fill(5), allowCredentials: [{ type: 'public-key', id: new Uint8Array([9, 9, 9]) }] } }); out.noCred = 'ALLOWED'; } catch (e) { out.noCred = e.name; }
    // hostile inputs straight at the native handler
    const hnd = window.webkit.messageHandlers.bpasskey; const hostile = [];
    for (const msg of [{ op: 'get', options: { challenge: 5 } }, { op: 'get', options: { challenge: 'AAAAAAAAAAAAAAAAAAAAAA', allow: [{ id: '***' }] } }, { op: 'create', options: { challenge: 'AAAAAAAAAAAAAAAAAAAAAA', user: {} } }, { op: 'get', options: { challenge: 'AAAAAAAAAAAAAAAAAAAAAA', allow: Array(500).fill({ id: 'AAAA' }) } }, { op: 7 }, 'string', null, { op: 'get' }]) {
      try { await hnd.postMessage(msg); hostile.push('ALLOWED'); } catch (e) { hostile.push('rejected'); }
    }
    out.hostile = hostile.join(',');
    // a sub-frame may not use passkeys, nor cancel the top page's request
    const fr = document.createElement('iframe'); fr.src = 'about:blank'; document.body.appendChild(fr); await new Promise(r => setTimeout(r, 300));
    try { await fr.contentWindow.navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32).fill(7) } }); out.frame = 'ALLOWED'; } catch (e) { out.frame = e.name; }
    await new Promise(r => setTimeout(r, 3200));
    await gap();
    const ac = new AbortController(); ac.abort();
    try { await navigator.credentials.get({ publicKey: { challenge: new Uint8Array(32) }, signal: ac.signal }); out.abort = 'ALLOWED'; } catch (e) { out.abort = e.name; }
    } catch (e) { out.error = e.name + ': ' + e.message; }
    return JSON.stringify(out);
    """
    NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil); try? await Task.sleep(nanoseconds: 300_000_000)
    var res: Any?; do { res = try await w.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) } catch { log("- passkey page script error: \(error)") }
    let m = ((res as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] ?? [:]
    log("- passkeys through a real page: \(m)  origins seen by native: \(seenOrigins)")
    let created = m["created"] as? [String: Any] ?? [:], got = m["got"] as? [String: Any] ?? [:], cd = m["cd"] as? [String: Any] ?? [:]
    if m.isEmpty { fail("passkeys: the page script threw before returning results") }
    let ua = (m["ua"] as? String) ?? ""
    log("- user agent seen by pages: \(ua)")
    if !ua.contains("Version/") || !ua.contains("Safari/605.1.15") || !ua.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15") { fail("user agent does not look like Safari: \(ua)") }
    if (m["uvpaa"] as? Bool) != false { fail("passkeys: isUserVerifyingPlatformAuthenticatorAvailable must be false (no platform authenticator)") }
    if (created["type"] as? String) != "public-key" || (created["inst"] as? Bool) != true || (created["alg"] as? Int) != -7 || (created["pk"] as? Int ?? 0) < 60 { fail("passkeys: create() did not return a usable PublicKeyCredential \(created)") }
    if (created["transports"] as? [String]) != ["hybrid"] { fail("passkeys: transports should be hybrid") }
    if (cd["type"] as? String) != "webauthn.create" || (cd["origin"] as? String) != "http://localhost:\(port)" { fail("passkeys: clientDataJSON origin/type wrong \(cd)") }
    if (got["same"] as? Bool) != true || (got["sig"] as? Bool) != true || (got["uh"] as? String) != "1,2" { fail("passkeys: get() returned the wrong credential \(got)") }
    if (m["rpHashOK"] as? Bool) != true { fail("passkeys: authenticatorData rpIdHash is not sha256(localhost)") }
    if (m["badRp"] as? String) != "SecurityError" { fail("passkeys: a page asking for another site's rpId was not refused (\(m["badRp"] ?? "nil"): \(m["badRpMsg"] ?? ""), key window: \(win.isKeyWindow))") }
    if (m["noCred"] as? String) != "NotAllowedError" { fail("passkeys: no-matching-credential should be NotAllowedError (\(m["noCred"] ?? "nil"))") }
    if (m["abort"] as? String) != "AbortError" { fail("passkeys: an aborted signal should reject with AbortError (\(m["abort"] ?? "nil"))") }
    if seenOrigins.contains(where: { !$0.hasPrefix("http://localhost:\(port)|localhost") }) { fail("passkeys: native saw a wrong origin/rpId \(seenOrigins)") }
    win.close()
  }

  // 10e. Browser identity: Safari by default, selectable Chrome / Firefox / Edge, applied to new and open tabs
  do {
    let saved = BrowserIdentity.current; defer { BrowserIdentity.current = saved }
    let factory = WebKitTabFactory(persistent: false)
    var seen: [String: String] = [:]
    for id in BrowserIdentity.allCases {
      factory.setIdentity(id)
      let t = factory.makeTab(id: TabID(), url: nil, profile: ProfileID(), restoredState: nil) as! WebKitTab
      let w = t.ensureLive(); w.loadHTMLString("<html><body>ua</body></html>", baseURL: URL(string: "http://localhost/"))
      _ = await waitUntil(15) { w.isLoading == false }
      seen[id.rawValue] = (try? await w.evaluateJavaScript("navigator.userAgent")) as? String ?? "?"
    }
    log("- identities: \(seen)")
    if !(seen["safari"] ?? "").contains("Version/") || !(seen["safari"] ?? "").contains("Safari/605.1.15") { fail("identity: default is not Safari \(seen["safari"] ?? "nil")") }
    if !(seen["chrome"] ?? "").contains("Chrome/145") || (seen["chrome"] ?? "").contains("Edg/") { fail("identity: chrome wrong \(seen["chrome"] ?? "nil")") }
    if !(seen["firefox"] ?? "").contains("Firefox/145") || !(seen["firefox"] ?? "").contains("Gecko/") { fail("identity: firefox wrong \(seen["firefox"] ?? "nil")") }
    if !(seen["edge"] ?? "").contains("Edg/145") { fail("identity: edge wrong \(seen["edge"] ?? "nil")") }
    // switching on an open tab changes the next load
    factory.setIdentity(.safari)
    let t = factory.makeTab(id: TabID(), url: nil, profile: ProfileID(), restoredState: nil) as! WebKitTab; let w = t.ensureLive()
    w.loadHTMLString("<html><body>a</body></html>", baseURL: URL(string: "http://localhost/")); _ = await waitUntil(15) { w.isLoading == false }
    factory.setIdentity(.firefox); w.loadHTMLString("<html><body>b</body></html>", baseURL: URL(string: "http://localhost/")); _ = await waitUntil(15) { w.isLoading == false }
    let after = (try? await w.evaluateJavaScript("navigator.userAgent")) as? String ?? "?"
    if !after.contains("Firefox/") { fail("identity: switching an open tab did not apply to its next load (\(after))") }
  }

  // 11. Navigation security, popups, errors, downloads, capture — real WebKit
  do {
    try? """
    <html><head><title>nav</title></head><body>
    <a id=blank target=_blank href="/t0.html">b</a> <a id=js href="javascript:window.__x=1;void 0">j</a> <a id=mail href="mailto:a@b.com">m</a>
    <a id=file href="file:///etc/hosts">f</a> <a id=data href="data:text/html,<h1>x</h1>">d</a> <a id=ok href="/t3.html">ok</a>
    </body></html>
    """.write(toFile: "\(pagesDir!)/nav.html", atomically: true, encoding: .utf8)
    let nt = WebKitTab(url: URL(string: "\(baseURL!)/nav.html")!, configuration: cfg); let nw = nt.ensureLive()
    let nwin = NSWindow(contentRect: nw.frame, styleMask: [.titled], backing: .buffered, defer: false); nwin.contentView = nw; nwin.orderBack(nil)
    var opened: [URL] = [], external: [URL] = []
    nt.onOpenURL = { opened.append($0) }; nt.onOpenExternally = { external.append($0) }
    _ = await waitUntil(20) { nw.isLoading == false && nw.url != nil }; try? await Task.sleep(nanoseconds: 500_000_000)
    @MainActor func click(_ id: String) async { _ = try? await nw.evaluateJavaScript("document.getElementById('\(id)').click(); 0"); try? await Task.sleep(nanoseconds: 500_000_000) }
    await click("blank"); if opened.count == 1 && opened[0].lastPathComponent == "t0.html" { log("- target=_blank became a tab request, no popup window") } else { fail("target=_blank handling: \(opened)") }
    await click("js"); let jsRan = ((try? await nw.evaluateJavaScript("window.__x === 1")) as? Bool) ?? false
    // FINDING: javascript: hrefs run in the page's OWN context and never reach decidePolicyFor. Not an escalation (the page can run that code anyway; typed javascript: is refused by URLInput).
    log("- javascript: href executed in-page = \(jsRan) (WebKit does not route it through navigation policy; same-origin only, no escalation)")
    await click("mail"); if external.count == 1 && external[0].scheme == "mailto" { log("- mailto: click handed to the system (user click)") } else { fail("mailto click not routed externally: \(external)") }
    external.removeAll(); _ = try? await nw.evaluateJavaScript("location.href = 'mailto:drive@by.com'; 0"); try? await Task.sleep(nanoseconds: 600_000_000)
    if external.isEmpty { log("- scripted mailto: redirect (no user click) was blocked") } else { fail("drive-by mailto launched an app: \(external)") }
    await click("file"); if nw.url?.scheme == "http" { log("- file: link blocked (\(nt.lastBlockedNavigation ?? "?"))") } else { fail("file: link navigated to \(nw.url?.absoluteString ?? "?")") }
    await click("data"); if nw.url?.scheme == "http" { log("- top-level data: link blocked") } else { fail("data: link navigated to \(nw.url?.absoluteString ?? "?")") }
    await click("ok"); _ = await waitUntil(15) { nw.url?.lastPathComponent == "t3.html" }
    if nw.url?.lastPathComponent == "t3.html" { log("- normal http link still works") } else { fail("normal link did not navigate") }
    // error page for an unreachable server (closed port): safe built-in page, no scripts
    let et = WebKitTab(url: URL(string: "http://127.0.0.1:55555/")!, configuration: cfg); let ew = et.ensureLive()
    let ewin = NSWindow(contentRect: ew.frame, styleMask: [.titled], backing: .buffered, defer: false); ewin.contentView = ew; ewin.orderBack(nil)
    _ = await waitUntil(20) { ew.title == "Can't connect to the server" }
    if ew.title == "Can't connect to the server" { log("- unreachable server shows the built-in error page") } else { fail("error page missing (title: \(ew.title ?? "nil"), lastLoadError \(et.lastLoadError ?? "none"))") }
    // camera/microphone: NOT automated here. Enabling navigator.mediaDevices makes pages able to reach the macOS TCC prompt, which can
    // hang or terminate an app without NSCameraUsageDescription/NSMicrophoneUsageDescription. Tested manually in the signed-app phase.

    // downloads: hostile suggested filename, quarantine, never overwrite, never opened
    let ddir = URL(fileURLWithPath: "\(pagesDir!)/downloads-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: ddir, withIntermediateDirectories: true)
    let dc = DownloadCoordinator(directory: ddir)
    let dt = WebKitTab(url: URL(string: "\(baseURL!)/t3.html")!, configuration: cfg); let dw = dt.ensureLive()
    let dwin = NSWindow(contentRect: dw.frame, styleMask: [.titled], backing: .buffered, defer: false); dwin.contentView = dw; dwin.orderBack(nil)
    var dlCalls = 0; dt.onDownload = { dlCalls += 1; dc.adopt($0) }
    _ = await waitUntil(20) { dw.isLoading == false && dw.url != nil }
    for round in 1...2 { dw.load(URLRequest(url: URL(string: "\(baseURL!)/dl?name=../../evil.txt")!)); _ = await waitUntil(20) { dc.items.values.filter { if case .finished = $0.state { return true }; return false }.count >= round } }
    log("  - download debug: onDownload calls \(dlCalls), items \(dc.items.values.map { "\($0.name):\($0.state)" }), events \(dt.events), tab error \(dt.lastLoadError ?? "none"), blocked \(dt.lastBlockedNavigation ?? "none")")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: ddir.path).sorted()) ?? []
    let escaped = FileManager.default.fileExists(atPath: "\(pagesDir!)/evil.txt") || FileManager.default.fileExists(atPath: ddir.deletingLastPathComponent().appendingPathComponent("evil.txt").path)
    var q = [CChar](repeating: 0, count: 256); let qlen = files.first.map { getxattr(ddir.appendingPathComponent($0).path, "com.apple.quarantine", &q, 256, 0, 0) } ?? -1
    log("- downloads: files \(files); quarantine xattr \(qlen > 0 ? "set" : "MISSING"); escaped directory: \(escaped)")
    if files.count != 2 || escaped || qlen <= 0 || files.contains(where: { $0.contains("/") || $0.hasPrefix(".") }) { fail("download safety: files=\(files) escaped=\(escaped) quarantine=\(qlen)") }
  }

  // hostile memory: a page that allocates ~1.3 GB/s must be cut off by the per-tab cap, shown an explanation, and not resumed
  do {
    try? "<title>membomb</title><script>const a=[];setInterval(()=>{try{a.push(new Uint8Array(64*1024*1024).fill(1))}catch(e){}},50)</script>".write(toFile: "\(pagesDir!)/membomb.html", atomically: true, encoding: .utf8)
    var capCfg = PolicyConfig(); capCfg.tabMemoryCapMB = 1000
    let lm = LifecycleManager(config: capCfg)
    let mt = WebKitTab(url: URL(string: "\(baseURL!)/membomb.html")!, configuration: cfg); let mw = mt.ensureLive()
    let mwin = NSWindow(contentRect: mw.frame, styleMask: [.titled], backing: .buffered, defer: false); mwin.contentView = mw; mwin.orderBack(nil)
    lm.register(mt, host: "127.0.0.1"); lm.activate(mt.id)
    let started = Date(); var peak = 0.0; var stoppedAt: Double?
    while Date().timeIntervalSince(started) < 40 {
      try? await Task.sleep(nanoseconds: 1_000_000_000)                                  // the production watchdog interval
      peak = max(peak, mb(mt.memoryBytes ?? 0))
      if !lm.memoryWatchdog().isEmpty { stoppedAt = Date().timeIntervalSince(started); break }
    }
    let freed = mt.memoryBytes == nil
    let shown = mt.ensureLive(); _ = await waitUntil(15) { shown.title == "This page was stopped" }
    let title = shown.title ?? "-"
    log("- hostile memory: cap 1000 MB; peak seen \(Int(peak)) MB; stopped after \(stoppedAt.map { String(format: "%.0f s", $0) } ?? "never"); process freed: \(freed); tab now shows \"\(title)\" (host \(Int(hostMB())) MB)")
    let keptURL = mt.currentURL?.absoluteString == "\(baseURL!)/membomb.html"
    mt.reload(); _ = await waitUntil(15) { shown.title == "membomb" }
    let reran = shown.title == "membomb"; mt.hibernate(force: true)                // user pressed Reload: the REAL page runs again (then we put it to sleep)
    log("- hostile memory: tab kept its real URL: \(keptURL); Reload re-ran the real page: \(reran)")
    if !keptURL || !reran { fail("stopped tab: keptURL=\(keptURL) reloadReran=\(reran)") }
    if stoppedAt == nil || !freed || title != "This page was stopped" || peak > 1000 + 3500 { fail("memory cap: stoppedAt=\(String(describing: stoppedAt)) freed=\(freed) title=\(title) peak=\(Int(peak))") }
  }

  log("\n**Result:** \(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))")")
  if let p = outPath { try? report.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) }
  exit(failures.isEmpty ? 0 : 1)
}
final class WeakBox { weak var ref: WKWebView?; init(_ r: WKWebView) { ref = r } }
app.run()
