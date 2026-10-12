import AppKit
import BrowserCore
import Darwin
import EngineWebKit
import Foundation
import Lifecycle
import Persistence
import Resources
import WebKit

// Scale / soak harness: N tabs (default 500) of mixed page types, ~100 live, heavy-tailed usage, adaptive policy driving hibernation.
// usage: EngineScale tabs liveBudget activations soakSeconds out.md pagesDir baseURL   (scripts/scale.sh wires the server)
setvbuf(stdout, nil, _IONBF, 0)
let a = CommandLine.arguments
guard a.count >= 8 else { print("usage: EngineScale tabs liveBudget activations soakSeconds out.md pagesDir baseURL"); exit(2) }
let N = Int(a[1]) ?? 500, LIVE = Int(a[2]) ?? 100, ACTIVATIONS = Int(a[3]) ?? 300, SOAK = Double(a[4]) ?? 0
let outPath = a[5], pagesDir = a[6], baseURL = a[7]
let app = NSApplication.shared; app.setActivationPolicy(.accessory)

nonisolated(unsafe) var report: [String] = []
nonisolated(unsafe) var failures: [String] = []
func log(_ s: String) { print(s); report.append(s) }
func fail(_ s: String) { print("FAIL \(s)"); failures.append(s); report.append("- **FAIL** \(s)") }
func mb(_ b: UInt64) -> Double { Double(b) / 1_048_576 }
func f0(_ x: Double) -> String { String(format: "%.0f", x) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

enum Kind: String, CaseIterable { case light, article, spa, heavy, anim, chatty, audio }
func kind(for i: Int) -> Kind { let m = i % 100; return m < 40 ? .light : m < 65 ? .article : m < 80 ? .spa : m < 88 ? .heavy : m < 94 ? .anim : m < 98 ? .chatty : .audio }

func html(_ k: Kind, _ i: Int) -> String {
  let head = "<html><head><meta charset=utf-8><title>tab \(i) \(k.rawValue)</title></head><body><h1>tab \(i) \(k.rawValue)</h1>"
  switch k {
  case .light: return head + "<p>" + String(repeating: "lorem ipsum dolor sit amet ", count: 150) + "</p></body></html>"
  case .article: return head + "<script>const d=document.createElement('div');for(let k=0;k<4000;k++){const p=document.createElement('p');p.textContent='paragraph '+k+' of tab \(i) '+'x'.repeat(40);d.appendChild(p)}document.body.appendChild(d)</script></body></html>"
  case .spa: return head + "<div id=o></div><script>const data=Array.from({length:150000},(_,k)=>({id:k,s:'row'+k,t:[k,k+1]}));setInterval(()=>{const o=document.getElementById('o');o.textContent='';for(let k=0;k<60;k++){const e=document.createElement('div');e.textContent=data[(Math.random()*data.length)|0].s;o.appendChild(e)}},1000)</script></body></html>"
  case .heavy: return head + "<script>const a=new Float64Array(40*131072);for(let k=0;k<a.length;k+=256)a[k]=k;window.__a=a</script></body></html>"
  case .anim: return head + "<canvas id=c width=400 height=300></canvas><script>const c=document.getElementById('c').getContext('2d');let t=0;(function f(){t++;const g=c.createLinearGradient(0,0,400,300);g.addColorStop(0,'hsl('+(t%360)+',80%,50%)');g.addColorStop(1,'#222');c.fillStyle=g;c.fillRect(0,0,400,300);requestAnimationFrame(f)})()</script></body></html>"
  case .chatty: return head + "<script>setInterval(()=>fetch('/ping.txt?t=\(i)&n='+Date.now()).catch(()=>{}),2000)</script></body></html>"
  case .audio: return head + "<audio id=a loop></audio><script>function w(){const sr=8000,n=sr*2,b=new DataView(new ArrayBuffer(44+n*2)),s=(o,t)=>[...t].forEach((c,i)=>b.setUint8(o+i,c.charCodeAt(0)));s(0,'RIFF');b.setUint32(4,36+n*2,true);s(8,'WAVEfmt ');b.setUint32(16,16,true);b.setUint16(20,1,true);b.setUint16(22,1,true);b.setUint32(24,sr,true);b.setUint32(28,sr*2,true);b.setUint16(32,2,true);b.setUint16(34,16,true);s(36,'data');b.setUint32(40,n*2,true);for(let k=0;k<n;k++)b.setInt16(44+k*2,Math.sin(6.28*330*k/sr)*4000,true);return new Blob([b],{type:'audio/wav'})}const a=document.getElementById('a');a.src=URL.createObjectURL(w());a.volume=0.01;a.play()</script></body></html>"
  }
}

func swapUsedMB() -> Double {
  var u = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
  return sysctlbyname("vm.swapusage", &u, &sz, nil, 0) == 0 ? Double(u.xsu_used) / 1_048_576 : -1
}
func pageoutsTotal() -> UInt64 {
  var s = vm_statistics64(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
  let r = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
  return r == KERN_SUCCESS ? UInt64(s.pageouts) : 0
}
func pressureName(_ p: PressureLevel?) -> String { p.map { "\($0)" } ?? "?" }
func percentile(_ xs: [Double], _ p: Double) -> Double { guard !xs.isEmpty else { return 0 }; let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

@MainActor func waitUntil(_ timeout: Double, _ cond: () async -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(timeout)
  while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
  return await cond()
}

Task { @MainActor in
  let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()   // leaves nothing on disk
  for k in 0..<N { try? html(kind(for: k), k).write(toFile: "\(pagesDir)/s\(k).html", atomically: true, encoding: .utf8) }
  try? "ok".write(toFile: "\(pagesDir)/ping.txt", atomically: true, encoding: .utf8)
  log("# Engine scale run \(Date())\n- macOS \(ProcessInfo.processInfo.operatingSystemVersionString); tabs=\(N), live budget=\(LIVE), activations=\(ACTIVATIONS), soak=\(Int(SOAK)) s")
  log("- page mix: " + Kind.allCases.map { k in "\(k.rawValue) \((0..<N).filter { kind(for: $0) == k }.count)" }.joined(separator: ", "))
  if SystemPressure.current() != .normal || swapUsedMB() > 6500 || swapUsedMB() < 0 { fail("refusing to start: pressure \(pressureName(SystemPressure.current())), swap \(f0(swapUsedMB())) MB already in use (this Mac is busy)"); exit(1) }
  if false { fail("system memory pressure is CRITICAL at start (\(pressureName(SystemPressure.current()))): refusing to run"); exit(1) }
  let swap0 = swapUsedMB(), pageouts0 = pageoutsTotal(), host0 = ProcessMemory.selfFootprint

  var tabs: [WebKitTab] = []; var windows: [NSWindow] = []
  var model = BrowserState(); let profile = ProfileID(); let space = model.addSpace(name: "Scale", profile: profile)
  var recordIDs: [TabID] = []
  var usage = UsageModel()
  var pc = PolicyConfig.relaxed; pc.maxLive = .init(normal: LIVE, warning: LIVE * 3 / 4, critical: LIVE / 2)   // the PRODUCT policy, not the neutral test base
  var lastDeactivated: [TabID: Date] = [:]
  var sim = Date()                                   // simulated clock: tabs age realistically without waiting hours
  var lastActive: [TabID: Date] = [:]

  @MainActor func liveTabs() -> [WebKitTab] { tabs.filter { $0.isLive } }
  @MainActor func totalMB() -> (web: Double, procs: Int) {
    var seen = Set<pid_t>(); var tot: UInt64 = 0
    for t in tabs where t.isLive { if let p = t.processID, seen.insert(p).inserted, let f = WebKitTab.footprint(pid: p) { tot += f } }
    return (mb(tot), seen.count)
  }
  /// One policy pass using real signals; returns (#hibernated, evaluation ms).
  @MainActor func policyPass() async -> (Int, Double) {
    let now = sim
    var infos: [TabInfo] = []
    for (i, t) in tabs.enumerated() {
      var ti = TabInfo(id: t.id, host: "site\(i % 60).example", lastActive: lastActive[t.id] ?? .distantPast)
      ti.liveness = t.isLive ? .live : .hibernated
      if t.isLive { let s = await t.signals(); ti.isLoading = s.isLoading; ti.isPlayingMedia = s.isPlayingMedia; ti.hasUnsavedForm = s.hasDirtyForm; ti.isCapturing = s.isCapturing }
      ti.isActive = (i == activeIndex); infos.append(ti)
    }
    let t0 = Date()
    let d = HibernationPolicy.evaluate(tabs: infos, pressure: SystemPressure.current() ?? .normal, usage: usage, now: now, config: pc)
    let ms = Date().timeIntervalSince(t0) * 1000
    for (j, t) in tabs.enumerated() { t.isActive = (j == activeIndex) }   // hibernate() re-checks: the user may have switched mid-pass
    var n = 0
    for id in d.hibernate { if let i = tabs.firstIndex(where: { $0.id == id }) { windows[i].contentView = NSView(); if tabs[i].hibernate() { n += 1 } } }
    return (n, ms)
  }
  var activeIndex = -1
  var warningSeen = 0

  /// Fail-closed memory guard. Returns a reason string if the Mac is in trouble (or the swap reading is unavailable).
  @MainActor func guardReason() -> String? {
    let sw = swapUsedMB()
    if sw < 0 { return "swap usage unreadable (failing closed)" }
    if SystemPressure.current() == .critical { return "system memory pressure CRITICAL" }
    if sw > swap0 + 1500 { return "swap grew \(f0(sw - swap0)) MB" }
    return nil
  }
  @MainActor func abortGuard(_ why: String, phase: String) -> Never {
    fail("memory guard tripped during \(phase): \(why)")
    for (j, t) in tabs.enumerated() where t.isLive { windows[j].contentView = NSView(); t.hibernate(force: true) }
    log("\n**Result:** ABORTED by memory guard"); try? report.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8); exit(1)
  }
  // 1. build N tabs; policy keeps the live set bounded while creating
  let t0 = Date()
  for i in 0..<N {
    let rid = model.addTab(in: space, url: "\(baseURL)/s\(i).html", title: "tab \(i)", now: sim)!
    recordIDs.append(rid); lastActive[rid] = sim
    let t = WebKitTab(id: rid, url: URL(string: "\(baseURL)/s\(i).html"), configuration: cfg)
    let w = t.ensureLive()
    let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil)
    tabs.append(t); windows.append(win)
    if i % 20 == 19 {
      _ = await waitUntil(30) { tabs.suffix(20).allSatisfy { $0.webView?.isLoading == false } }
      sim = sim.addingTimeInterval(360); _ = await policyPass()   // a person opens ~20 tabs over several minutes, not in 0.3 s
      // SAFETY GUARD: never push this Mac into memory trouble
      if SystemPressure.current() == .warning { warningSeen += 1 }
      if let why = guardReason() { abortGuard(why, phase: "build at \(i + 1) tabs") }
    }
  }
  _ = await waitUntil(60) { liveTabs().allSatisfy { $0.webView?.isLoading == false } }
  _ = await policyPass()
  let buildS = Date().timeIntervalSince(t0)
  var m = totalMB()
  log("- memory-pressure WARNING observed on \(warningSeen) of \(N / 20) build batches (policy tightens the budget at warning)")
  log("- built \(N) tabs in \(f0(buildS)) s -> live \(liveTabs().count), hibernated \(N - liveTabs().count)")
  log("- steady state: WebContent **\(f0(m.web)) MB** in \(m.procs) processes, host \(f0(mb(ProcessMemory.selfFootprint))) MB, swap \(f0(swapUsedMB())) MB (start \(f0(swap0))), pressure \(pressureName(SystemPressure.current()))")
  let perTab = m.procs > 0 ? m.web / Double(m.procs) : 0
  log("- measured ~\(f1(perTab)) MB WebContent per live tab; ESTIMATE if all \(N) were live: \(f0(perTab * Double(N))) MB (this Mac has \(f0(Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576)) MB RAM)")
  let floorNow = pc.validated().budgetFloor.normal
  let oldLive = tabs.enumerated().filter { $0.element.isLive && sim.timeIntervalSince(lastActive[$0.element.id] ?? .distantPast) >= floorNow }.count
  log("- live tabs older than the \(Int(floorNow)) s budget floor: \(oldLive) (budget \(LIVE)); recently-used tabs are protected by design")
  if oldLive > LIVE { fail("\(oldLive) live tabs older than the floor exceed budget \(LIVE)") }

  // 2. store at scale: save/load/size, tab-state blobs
  let dbPath = "\(pagesDir)/scale.sqlite"
  do {
    let store = try Store(path: dbPath)
    let w0 = model.openWindow(space: space); _ = w0
    let ts = Date(); try store.save(model); let saveMs = Date().timeIntervalSince(ts) * 1000
    let tl = Date(); let back = try store.load(); let loadMs = Date().timeIntervalSince(tl) * 1000
    var blobBytes = 0; let tb = Date()
    for (i, t) in tabs.enumerated() where !t.isLive { if let d = t.restorableState { try store.setTabState(t.id, d); blobBytes += d.count }; _ = i }
    let blobMs = Date().timeIntervalSince(tb) * 1000
    let size = ((try? FileManager.default.attributesOfItem(atPath: dbPath))?[.size] as? Int) ?? 0
    log("- store @\(N) tabs: save \(f0(saveMs)) ms, load \(f0(loadMs)) ms, round-trip equal \(back == model); hibernated tab states \(blobBytes / 1024) KB written in \(f0(blobMs)) ms; db \(size / 1024) KB")
    if back != model { fail("store round trip mismatch at \(N) tabs") }
    if saveMs > 2000 { fail("store save took \(f0(saveMs)) ms at \(N) tabs (>2 s)") }
  } catch { fail("store at scale threw: \(error)") }

  // 3. heavy-tailed usage: hot tabs get most activations; measure live-hit ratio and resume latency
  var rng = RNG(s: 20261013)
  var perm = Array(0..<N); for i in stride(from: N - 1, to: 0, by: -1) { let j = Int(rng.next() * Double(i + 1)); perm.swapAt(i, j) }
  func zipfPick() -> Int { let u = rng.next(); let r = Int(pow(Double(N), u)) - 1; return perm[max(0, min(N - 1, r))] }   // log-uniform ~ 1/rank
  var hits = 0, latencies: [Double] = [], hostSamples: [Double] = [host0 > 0 ? mb(host0) : 0]
  var policyMs: [Double] = []
  for k in 0..<ACTIVATIONS {
    let i = zipfPick(); let t = tabs[i]
    sim = sim.addingTimeInterval(150)                  // ~400 activations span ~16 simulated hours so time-based grace participates
    if let ld = lastDeactivated[t.id] { usage.recordReactivation(host: "site\(i % 60).example", idleSeconds: sim.timeIntervalSince(ld)) }
    if activeIndex >= 0 { lastDeactivated[tabs[activeIndex].id] = sim }
    activeIndex = i; lastActive[t.id] = sim
    let ts = Date()
    if t.isLive { hits += 1; latencies.append(0) }
    else {
      windows[i].contentView = t.ensureLive()
      let ok = await waitUntil(30) { t.webView?.isLoading == false && t.webView?.url != nil }
      if !ok { fail("activation \(k): tab \(i) did not become ready in 30 s") }
      latencies.append(Date().timeIntervalSince(ts) * 1000)
    }
    _ = model.select(tab: recordIDs[i], in: model.openWindow(space: space) ?? WindowID())   // keep model LRU current
    if k % 10 == 9 { let (n, ms) = await policyPass(); policyMs.append(ms); _ = n; if let why = guardReason() { abortGuard(why, phase: "activations") } }
    if k % 50 == 49 { hostSamples.append(mb(ProcessMemory.selfFootprint)) }
  }
  let missLat = latencies.filter { $0 > 0 }
  log("- \(ACTIVATIONS) heavy-tailed activations: live-hit **\(f0(Double(hits) / Double(ACTIVATIONS) * 100))%**, resume latency of misses p50 \(f0(percentile(missLat, 0.5))) / p95 \(f0(percentile(missLat, 0.95))) / p99 \(f0(percentile(missLat, 0.99))) ms (n=\(missLat.count))")
  log("- policy evaluation at \(N) tabs: median \(f1(percentile(policyMs, 0.5))) ms, max \(f1(policyMs.max() ?? 0)) ms (includes only the pure policy call)")
  m = totalMB()
  log("- after churn: WebContent \(f0(m.web)) MB / \(m.procs) procs, live \(liveTabs().count), host \(f0(mb(ProcessMemory.selfFootprint))) MB, swap \(f0(swapUsedMB())) MB, pageouts +\(pageoutsTotal() - pageouts0), pressure \(pressureName(SystemPressure.current()))")
  if let h = hostSamples.last, h > mb(host0) + 400 { fail("host memory grew to \(f0(h)) MB") }

  // 4. optional soak: keep churning with periodic samples; detect drift
  if SOAK > 0 {
    log("\n## Soak \(Int(SOAK)) s (sample every 30 s)\n\n| t(s) | live | WebContent MB | procs | host MB | swap MB | pressure |\n|---|---|---|---|---|---|---|")
    let end = Date().addingTimeInterval(SOAK); var nextSample = Date(); var series: [(Double, Double)] = []
    while Date() < end {
      let i = zipfPick(); let t = tabs[i]
      sim = sim.addingTimeInterval(20)
      if let ld = lastDeactivated[t.id] { usage.recordReactivation(host: "site\(i % 60).example", idleSeconds: sim.timeIntervalSince(ld)) }
      if activeIndex >= 0 { lastDeactivated[tabs[activeIndex].id] = sim }
      activeIndex = i; lastActive[t.id] = sim
      if !t.isLive { windows[i].contentView = t.ensureLive() }
      try? await Task.sleep(nanoseconds: 400_000_000)
      if Int(Date().timeIntervalSince1970) % 5 == 0 { _ = await policyPass() }
      if Date() >= nextSample {
        nextSample = Date().addingTimeInterval(30); let mm = totalMB(); let el = SOAK - end.timeIntervalSinceNow
        log("| \(f0(el)) | \(liveTabs().count) | \(f0(mm.web)) | \(mm.procs) | \(f0(mb(ProcessMemory.selfFootprint))) | \(f0(swapUsedMB())) | \(pressureName(SystemPressure.current())) |")
        series.append((el, mm.web + mb(ProcessMemory.selfFootprint)))
        if let why = guardReason() { abortGuard(why, phase: "soak") }
      }
    }
    if series.count >= 6 {   // slope of total memory over the second half
      let h = Array(series.suffix(series.count / 2)); let n = Double(h.count)
      let mx = h.map(\.0).reduce(0, +) / n, my = h.map(\.1).reduce(0, +) / n
      let slope = h.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +) / max(h.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +), 1)
      log("- soak memory slope (2nd half): \(f1(slope * 3600)) MB/hour (≈0 = no leak)")
      if slope * 3600 > 300 { fail("memory growing \(f0(slope * 3600)) MB/hour during soak") }
    }
  }

  // 5. protected tabs survived? audio tabs must never have been hibernated
  let audioIdx = (0..<N).filter { kind(for: $0) == .audio }
  let audioLive = audioIdx.filter { tabs[$0].isLive }.count
  let audioHib = audioIdx.reduce(0) { $0 + tabs[$1].hibernateCount }
  log("- audio tabs: \(audioLive)/\(audioIdx.count) still live, hibernations: \(audioHib)")
  if audioHib > 0 { fail("an audio-playing tab was hibernated \(audioHib) times") }

  log("\n**Result:** \(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))")")
  try? report.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
  exit(failures.isEmpty ? 0 : 1)
}
app.run()
