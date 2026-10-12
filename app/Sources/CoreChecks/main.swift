import BrowserCore
import Foundation
import Lifecycle
import Persistence
import Resources
import SQLite3

// Self-checking tests (XCTest unavailable under Command Line Tools). Exit non-zero on any failure.
// Crash-writer child mode (spawned by section 13): saves forever, gets SIGKILLed by the parent. MUST run before anything else.
if CommandLine.arguments.contains("--crash-writer"), let pi = CommandLine.arguments.firstIndex(of: "--crash-writer") {
  let wp = CommandLine.arguments[pi + 1]
  guard let ws = try? Store(path: wp) else { exit(3) }
  guard (try? ws.load()) != nil else { exit(3) }
  var gen = 0
  while true {
    gen += 1; var s = BrowserState(); let sp = s.addSpace(name: "g\(gen)", profile: ProfileID())
    for i in 0..<400 { s.addTab(in: sp, url: "https://crash.example/\(gen)/\(i)", title: String(repeating: "t", count: 200)) }
    _ = s.openWindow(space: sp)
    do { try ws.save(s) } catch { exit(4) }
  }
}
nonisolated(unsafe) var failures = 0
func check(_ cond: @autoclosure () throws -> Bool, _ name: String) { let ok = (try? cond()) ?? false; if ok { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 } }

let now = Date(timeIntervalSince1970: 1_000_000)
let min = 60.0
func tab(_ host: String, idle: TimeInterval, _ cfg: (inout TabInfo) -> Void = { _ in }) -> TabInfo {
  var t = TabInfo(host: host, lastActive: now.addingTimeInterval(-idle)); cfg(&t); return t
}
func hib(_ tabs: [TabInfo], _ p: PressureLevel = .normal, usage: UsageModel = UsageModel(), wake: Date? = nil, config: PolicyConfig = .init()) -> [TabID] {
  HibernationPolicy.evaluate(tabs: tabs, pressure: p, usage: usage, now: now, lastWake: wake, config: config).hibernate
}
let cfg = PolicyConfig()

// 1. Anything playing/capturing/transferring/unsaved is NEVER hibernated: any pressure, any idle time, any config.
let flags: [(String, (inout TabInfo) -> Void)] = [
  ("active", { $0.isActive = true }), ("audible", { $0.isAudible = true }), ("media", { $0.isPlayingMedia = true }),
  ("pip", { $0.isPictureInPicture = true }), ("capture", { $0.isCapturing = true }), ("call", { $0.isInCall = true }),
  ("download", { $0.isDownloading = true }), ("form", { $0.hasUnsavedForm = true }), ("upload", { $0.hasInflightUpload = true }),
  ("loading", { $0.isLoading = true }), ("userRule", { $0.userProtected = true }), ("devtools", { $0.isDevToolsOpen = true }),
]
var aggressive = PolicyConfig(); aggressive.defaultGrace = 1; aggressive.minGrace = 1; aggressive.criticalFloor = 1
aggressive.maxLive = .init(normal: 1, warning: 1, critical: 1)
for level in [PressureLevel.normal, .warning, .critical] {
  for (name, f) in flags {
    let t = tab("netflix.com", idle: 30 * 86_400, f)
    check(hib([t], level).isEmpty, "protected(\(name)) never hibernated @\(level)")
    check(hib([t, tab("other.com", idle: 86_400), tab("third.com", idle: 86_400)], level, config: aggressive).contains(t.id) == false, "protected(\(name)) survives aggressive config + budget @\(level)")
  }
}
let d0 = HibernationPolicy.evaluate(tabs: [tab("x.com", idle: 100, { $0.isPictureInPicture = true })], pressure: .normal, usage: UsageModel(), now: now)
check(d0.protected.values.first == [.pictureInPicture], "PiP reported as the reason")

// 2. Defaults: 5-minute-idle tab stays alive at normal AND warning pressure; hour-idle tab is released.
let five = tab("example.com", idle: 5 * min)
check(hib([five], .normal).isEmpty, "5 min idle live @normal")
check(hib([five], .warning).isEmpty, "5 min idle live @warning")
check(hib([tab("example.com", idle: 14 * min)], .warning).isEmpty, "14 min idle live @warning (floor 15 min)")
check(hib([tab("example.com", idle: 29 * min)], .warning).isEmpty, "29 min idle live @warning (grace 30 min)")
check(hib([tab("example.com", idle: 31 * min)], .warning).count == 1, "31 min idle hibernates @warning")
check(hib([tab("example.com", idle: 59 * min)], .normal).isEmpty, "59 min idle live @normal")
check(hib([tab("example.com", idle: 61 * min)], .normal).count == 1, "61 min idle hibernates @normal")
check(hib([five], .critical).isEmpty, "5 min idle live even @critical (floor 5 min, not exceeded)")
check(hib([tab("example.com", idle: 14 * min)], .critical).isEmpty, "14 min idle live @critical (grace 15 min)")
check(hib([tab("example.com", idle: 16 * min)], .critical).count == 1, "16 min idle hibernates @critical")
var tight = PolicyConfig(); tight.pressureScale = .init(normal: 1, warning: 0.5, critical: 0.05); tight.criticalFloor = 5 * 60
check(hib([tab("example.com", idle: 4 * min)], .critical, config: tight).isEmpty && hib([tab("example.com", idle: 6 * min)], .critical, config: tight).count == 1, "user critical floor (5 min) is the lower bound")
check(hib([tab("example.com", idle: 20)], .critical).isEmpty, "20 s idle never hibernated")

// 3. User settings are honored.
var mine = PolicyConfig(); mine.defaultGrace = 6 * 3600
check(hib([tab("example.com", idle: 5 * 3600)], config: mine).isEmpty, "user: 6 h grace keeps 5 h-idle tab")
check(hib([tab("example.com", idle: 7 * 3600)], config: mine).count == 1, "user: 6 h grace releases 7 h-idle tab")
var off = PolicyConfig(); off.enabled = false
check(hib([tab("example.com", idle: 30 * 86_400)], config: off).isEmpty, "user: hibernation disabled")

// 4. Validation clamps bad input; Codable round-trips.
var bad = PolicyConfig(); bad.defaultGrace = .nan; bad.minGrace = -5; bad.criticalFloor = .infinity; bad.gapFactor = 0
bad.pressureScale = .init(normal: 0, warning: 99, critical: -1); bad.maxLive = .init(normal: 0, warning: -3, critical: 0)
let v = bad.validated()
check(v.minGrace >= 30 && v.defaultGrace >= v.minGrace && v.criticalFloor <= v.minGrace && v.criticalFloor >= 30, "validated(): grace ordering + floors")
check(v.gapFactor >= 1 && v.pressureScale.normal >= 0.05 && v.pressureScale.warning <= 1 && v.maxLive.normal >= 1 && v.maxLive.warning >= 1, "validated(): scales and budgets in range")
check(hib([tab("a.com", idle: 100)], config: bad).isEmpty, "garbage config does not hibernate fresh tabs")
let enc = try JSONEncoder().encode(mine); let dec = try JSONDecoder().decode(PolicyConfig.self, from: enc)
check(dec.defaultGrace == mine.defaultGrace && dec.maxLive.critical == mine.maxLive.critical, "config JSON round-trip")

// 5. Adaptive: habitual quick-return host kept live ~1.5x its gap; rare hosts use the default.
var usage = UsageModel(); for _ in 0..<5 { usage.recordReactivation(host: "docs.example", idleSeconds: 20 * min) }
check(hib([tab("docs.example", idle: 55 * min)], usage: usage).isEmpty, "habitual host (gap 20 min) kept live ~3x its gap (60 min)")
check(hib([tab("docs.example", idle: 61 * min)], usage: usage).count == 1, "habitual host released after ~3x its gap")
var coldU = UsageModel(); for _ in 0..<5 { coldU.recordReactivation(host: "rare.example", idleSeconds: 3 * 3600) }
check(hib([tab("rare.example", idle: 14 * min)], usage: coldU).isEmpty && hib([tab("rare.example", idle: 16 * min)], usage: coldU).count == 1, "cold host (usual gap 3 h) is released early (min grace 15 min)")
var hotU = UsageModel(); for _ in 0..<5 { hotU.recordReactivation(host: "chat.example", idleSeconds: 2 * min) }
check(hib([tab("chat.example", idle: 14 * min)], usage: hotU).isEmpty, "hot host never dropped below the min grace")
var bigGap = UsageModel(); for _ in 0..<5 { bigGap.recordReactivation(host: "slowish.example", idleSeconds: 40 * min) }
check(hib([tab("slowish.example", idle: 100 * min)], usage: bigGap).isEmpty && hib([tab("slowish.example", idle: 125 * min)], usage: bigGap).count == 1, "gap 40 min -> grace 120 min (3x)")
// budget: shed the tab whose OWN grace would expire soonest (cold before habitual)
var ob = PolicyConfig(); ob.maxLive = .init(normal: 1, warning: 1, critical: 1)
var coldHot = UsageModel(); for _ in 0..<5 { coldHot.recordReactivation(host: "habit.example", idleSeconds: 20 * min); coldHot.recordReactivation(host: "rare.example", idleSeconds: 3 * 3600) }
let habitTab = tab("habit.example", idle: 10 * min), rareTab = tab("rare.example", idle: 10 * min)
check(hib([habitTab, rareTab], usage: coldHot, config: ob) == [rareTab.id], "over budget: the cold tab (grace 15 min) is shed before the habitual one (grace 60 min)")
check(hib([rareTab, habitTab], usage: coldHot, config: ob) == [rareTab.id], "budget order does not depend on input order")
// smooth taper: no cliff at coldGap
var taper = UsageModel(); for _ in 0..<5 { taper.recordReactivation(host: "t45", idleSeconds: 45 * min); taper.recordReactivation(host: "t46", idleSeconds: 46 * min) }
let g45 = HibernationPolicy.grace(for: tab("t45", idle: 0), pressure: .normal, usage: taper, config: PolicyConfig()), g46 = HibernationPolicy.grace(for: tab("t46", idle: 0), pressure: .normal, usage: taper, config: PolicyConfig())
check(abs(g46 - g45) < 0.1 * g45, "grace tapers smoothly across coldGap (45 min -> \(Int(g45 / 60)) min, 46 min -> \(Int(g46 / 60)) min)")
// censored observations raise, never lower
var cens = UsageModel(); cens.recordReactivation(host: "h", idleSeconds: 10 * min); let gapBefore = cens.expectedGap(host: "h")!
cens.recordNoReturn(host: "h", idleSeconds: 5 * min); check(cens.expectedGap(host: "h") == gapBefore, "no-return shorter than the gap changes nothing")
cens.recordNoReturn(host: "h", idleSeconds: 4 * 3600); check(cens.expectedGap(host: "h")! > gapBefore, "no-return observation raises the learned gap")
var nanAlpha = UsageModel(); nanAlpha.alpha = .nan; nanAlpha.recordReactivation(host: "x", idleSeconds: 60); nanAlpha.recordReactivation(host: "x", idleSeconds: 120)
check(nanAlpha.expectedGap(host: "x")?.isFinite == true, "NaN alpha cannot poison the model")
// grace products stay bounded; floors monotone
var huge = PolicyConfig(); huge.pinnedMultiplier = 20; huge.liveConnectionMultiplier = 20; huge.maxGrace = 7 * 86_400; huge.defaultGrace = 7 * 86_400
check(HibernationPolicy.grace(for: tab("a", idle: 0) { $0.isPinned = true; $0.hasLiveConnection = true }, pressure: .normal, usage: UsageModel(), config: huge.validated()) <= 7 * 86_400, "pinned x live-connection x default grace is capped at 7 days")
var inv = PolicyConfig(); inv.budgetFloor = .init(normal: 60, warning: 600, critical: 3000)
let iv = inv.validated(); check(iv.budgetFloor.critical <= iv.budgetFloor.warning && iv.budgetFloor.warning <= iv.budgetFloor.normal, "budget floors are monotone after validation")
check(hib([tab("rare.example", idle: 31 * min)], usage: usage).isEmpty, "unknown host uses default grace")
var tiny = UsageModel(); tiny.recordReactivation(host: "x", idleSeconds: .nan); tiny.recordReactivation(host: "z", idleSeconds: .infinity); tiny.recordReactivation(host: "y", idleSeconds: -10)
check(tiny.gaps["x"] == nil && tiny.gaps["z"] == nil && tiny.gaps["y"] == 0, "usage model ignores NaN/inf, clamps negatives")
var capped = UsageModel(); capped.maxHosts = 3; for i in 0..<10 { capped.recordReactivation(host: "h\(i)", idleSeconds: 60) }
check(capped.gaps.count == 3 && capped.gaps["h9"] != nil && capped.gaps["h0"] == nil, "usage model bounded; evicts oldest hosts")
let um = try JSONDecoder().decode(UsageModel.self, from: JSONEncoder().encode(usage))
check(um.expectedGap(host: "docs.example") == usage.expectedGap(host: "docs.example") && um.version == 1, "usage model JSON round-trip")

// 6. Pinned: longer grace.
check(hib([tab("example.com", idle: 2 * 3600, { $0.isPinned = true })]).isEmpty, "pinned tab outlasts default grace")

// 7. Budget: shed LRU beyond maxLive, keep protected, only tabs idle >= criticalFloor.
var many: [TabInfo] = (0..<20).map { i in tab("h\(i).example", idle: 6 * min + Double(i) * 10) }
many[0].isPlayingMedia = true
var bc = PolicyConfig(); bc.maxLive = .init(normal: 5, warning: 5, critical: 5)
let d = hib(many, .normal, config: bc)
check(d.count == 15 && !d.contains(many[0].id), "budget sheds to 5 live, keeps playing tab")
check(d.first == many[19].id, "LRU shed first")
let young: [TabInfo] = (0..<10).map { i in tab("y\(i).example", idle: 20) }
check(hib(young, .critical, config: bc).isEmpty, "budget never sheds tabs idle < the 30 s critical floor")
let mid: [TabInfo] = (0..<10).map { i in tab("m\(i).example", idle: 3 * min) }
check(hib(mid, .normal, config: bc).isEmpty, "normal pressure: 3-min-idle tabs are not shed by the budget (floor 5 min)")
check(hib(mid, .warning, config: bc).count == 5, "warning pressure: floor drops to 2 min, budget sheds 3-min-idle tabs down to 5 live")
let burst: [TabInfo] = (0..<10).map { i in tab("b\(i).example", idle: 45) }
check(hib(burst, .critical, config: bc).count == 5, "critical pressure: even 45 s-idle tabs are shed to the budget")
var wild = PolicyConfig(); wild.budgetFloor = .init(normal: -5, warning: .nan, critical: 1e12)
let wv = wild.validated(); check(wv.budgetFloor.normal >= 10 && wv.budgetFloor.warning >= 10 && wv.budgetFloor.critical <= 3600, "validated(): budget floors clamped")

// 8. Already-hibernated tabs ignored; empty input ok.
var h = tab("example.com", idle: 86_400); h.liveness = .hibernated
check(hib([h], .critical).isEmpty, "hibernated tab not re-selected")
check(hib([]).isEmpty, "no tabs, no decisions")

// 9. Review fixes: duplicates, wake, pinned-vs-budget, overBudget, reasons.
let dupID = TabID()
var p1 = TabInfo(id: dupID, host: "a.com", lastActive: now.addingTimeInterval(-86_400)); var p2 = p1; p2.isPlayingMedia = true
check(hib([p1, p2]).isEmpty, "duplicate ids: protected twin protects the id")
check(hib([p1, p1]).count == 1, "duplicate ids: emitted once")
let sleepy = tab("a.com", idle: 5 * 3600)
check(hib([sleepy]).count == 1, "5 h idle hibernates (no wake info)")
check(hib([sleepy], wake: now.addingTimeInterval(-30)).isEmpty, "just woke from sleep: nothing hibernated")
check(hib([tab("a.com", idle: -500)]).isEmpty, "future lastActive (clock jump) is safe")
var pc = PolicyConfig(); pc.maxLive = .init(normal: 1, warning: 1, critical: 1)
let pinnedOld = tab("p.com", idle: 20 * min) { $0.isPinned = true }, loose = tab("l.com", idle: 10 * min)
check(hib([pinnedOld, loose], config: pc) == [loose.id], "budget sheds unpinned before pinned")
var onlyProt = (0..<5).map { _ in tab("m.com", idle: 100) { $0.isPlayingMedia = true } }
let dp = HibernationPolicy.evaluate(tabs: onlyProt, pressure: .normal, usage: UsageModel(), now: now, config: pc)
check(dp.hibernate.isEmpty && dp.overBudget == 4, "all protected: nothing shed, overBudget reported")
onlyProt[0].isAudible = true
check(HibernationPolicy.evaluate(tabs: [onlyProt[0]], pressure: .normal, usage: UsageModel(), now: now).protected[onlyProt[0].id] == [.playingMedia, .audible].sorted { $0.rawValue < $1.rawValue }.reversed().sorted { Protection.allCases.firstIndex(of: $0)! < Protection.allCases.firstIndex(of: $1)! }, "multiple protection reasons reported in stable order")
var bw = PolicyConfig(); bw.maxLive = .init(normal: 5, warning: 5, critical: 5)
let mixed: [TabInfo] = (0..<8).map { i in tab("w\(i).com", idle: 10 * min) }
var withHib = mixed; withHib[0].liveness = .hibernated
check(hib(withHib, .warning, config: bw).count == 2, "budget counts only live tabs (7 live -> shed 2)")


// 9b. Recently-audible grace (borrowed idea: Chromium Memory Saver keeps recently audible tabs) + pressure mapping
let paused = tab("podcast.example", idle: 5 * 3600) { $0.lastAudible = now.addingTimeInterval(-3 * min) }
check(hib([paused]).isEmpty, "tab whose audio stopped 3 min ago stays live (grace 10 min)")
let paused2 = tab("podcast.example", idle: 5 * 3600) { $0.lastAudible = now.addingTimeInterval(-11 * min) }
check(hib([paused2]).count == 1, "tab whose audio stopped 11 min ago may hibernate")
var noGrace = PolicyConfig(); noGrace.audibleGrace = 0
check(hib([paused], config: noGrace).count == 1, "user can set audible grace to 0")
let futureAudible = tab("p.example", idle: 5 * 3600) { $0.lastAudible = now.addingTimeInterval(500) }
check(hib([futureAudible]).count == 1, "audible timestamp in the future (clock jump) does not protect forever")
check(SystemPressure.map(sysctlValue: 1) == .normal && SystemPressure.map(sysctlValue: 2) == .warning && SystemPressure.map(sysctlValue: 4) == .critical, "sysctl pressure values map to levels")
check(SystemPressure.map(event: [.warning]) == .warning && SystemPressure.map(event: [.critical]) == .critical && SystemPressure.map(event: [.normal]) == .normal, "dispatch pressure events map to levels")
check(SystemPressure.current() != nil, "kernel pressure level is readable on this Mac")
check(ProcessMemory.selfFootprint > 1_000_000 && ProcessMemory.footprint(pid: getpid()) != nil, "own memory footprint is readable")

// 9c. Product preset `.relaxed` (tuned on the simulator): long-lived tabs, pressure still tightens
let rx = PolicyConfig.relaxed
check(hib([tab("a.example", idle: 80 * min)], config: rx).isEmpty && hib([tab("a.example", idle: 100 * min)], config: rx).count == 1, "relaxed @normal: live at 80 min idle, hibernates at 100 min (grace 90)")
check(hib([tab("a.example", idle: 40 * min)], .warning, config: rx).isEmpty && hib([tab("a.example", idle: 50 * min)], .warning, config: rx).count == 1, "relaxed @warning: grace halves to 45 min")
check(hib([tab("a.example", idle: 20 * min)], .critical, config: rx).isEmpty && hib([tab("a.example", idle: 25 * min)], .critical, config: rx).count == 1, "relaxed @critical: grace 22.5 min")
check(hib([tab("a.example", idle: 5 * min)], .critical, config: rx).isEmpty, "relaxed @critical: never below the 10 min floor")
check(rx.validated().minGrace == rx.minGrace && rx.validated().maxLive.normal == 100, "relaxed preset survives validation unchanged")

// 9d. Live connections (WebSocket/EventSource): longer grace, but not an eternal pin
let sock = tab("chat.example", idle: 200 * min) { $0.hasLiveConnection = true }
check(hib([sock], config: rx).isEmpty, "relaxed: tab with a live connection survives 200 min idle (grace 270)")
check(hib([tab("chat.example", idle: 300 * min) { $0.hasLiveConnection = true }], config: rx).count == 1, "live-connection tab still hibernates eventually (300 min)")
check(hib([tab("chat.example", idle: 200 * min)], config: rx).count == 1, "same tab without a connection hibernates at 200 min")
var manySock: [TabInfo] = (0..<10).map { i in tab("w\(i).example", idle: 20 * min) { $0.hasLiveConnection = true } }
var sb = PolicyConfig.relaxed; sb.maxLive = .init(normal: 5, warning: 5, critical: 5)
check(hib(manySock, config: sb).count == 5, "live-connection tabs do not exempt a tab from the live budget")
manySock.removeAll()

// 10. Window / space / tab model (docs/architecture/window-model.md)
let prof1 = ProfileID(), prof2 = ProfileID()
var st = BrowserState()
let A = st.addSpace(name: "A", profile: prof1), B = st.addSpace(name: "B", profile: prof1), C = st.addSpace(name: "C", profile: prof2)
let a1 = st.addTab(in: A, url: "https://a1")!, a2 = st.addTab(in: A, url: "https://a2")!, a3 = st.addTab(in: A, url: "https://a3")!
let b1 = st.addTab(in: B, url: "https://b1")!
let w1 = st.openWindow(space: A)!, w2 = st.openWindow(space: A)!
check(st.windows[w1]!.selected == a1 && st.windows[w2]!.selected == a2, "second window on same space picks a free tab")
check(st.select(tab: a1, in: w2) == .focusWindow(w1) && st.windows[w2]!.selected == a2, "selecting a tab shown elsewhere focuses that window, no clone")
check(st.visibleTabs == [a1, a2], "visibleTabs = selections")
st.closeWindow(w2)
check(st.tabs[a2] != nil && st.space(A)!.tabOrder.count == 3, "closing a window never closes tabs")
let w3 = st.detachTab(a1)!
check(st.windows[w3]!.selected == a1 && st.windows[w1]!.selected != a1 && st.validate().isEmpty, "detach: new window on same space, old window picks neighbour")
// review fix: detaching the LAST tab must leave the holder with a free neighbour (previous tab), not nil
var d1 = BrowserState(); let ds = d1.addSpace(name: "D", profile: prof1)
let x1 = d1.addTab(in: ds, url: "u1")!, x2 = d1.addTab(in: ds, url: "u2")!, x3 = d1.addTab(in: ds, url: "u3")!
let dw = d1.openWindow(space: ds)!; _ = d1.select(tab: x3, in: dw); _ = d1.detachTab(x3)
check(d1.windows[dw]!.selected == x2 || d1.windows[dw]!.selected == x1, "detach last tab: holder falls back to previous neighbour")
check(d1.validate().isEmpty, "detach last tab keeps invariants")
st.switchSpace(window: w1, to: B); let inB = st.windows[w1]!.selected
st.switchSpace(window: w1, to: A)
check(inB == b1 && st.windows[w1]!.space == A && st.windows[w1]!.selected != nil && st.validate().isEmpty, "switchSpace round trip keeps a valid selection")
check(st.moveTab(a3, to: B) == .moved && st.tabs[a3]!.space == B, "move within same profile")
if case .needsProfileConfirmation(let f, let t) = st.moveTab(a3, to: C) { check(f == prof1 && t == prof2 && st.tabs[a3]!.space == B, "cross-profile move needs confirmation and does not move") } else { check(false, "cross-profile move needs confirmation") }
check(st.moveTab(a3, to: C, confirmedCrossProfile: true) == .moved && st.tabs[a3]!.space == C && st.validate().isEmpty, "confirmed cross-profile move")

// 10b. Closing sleeps, never destroys (user rule)
st.closeTab(a2)
check(st.tabs[a2] == nil && st.archive.contains { $0.id == a2 } && st.validate().isEmpty, "close tab -> archived, not destroyed")
check(st.restoreTab(a2) == .restored(a2) && st.tabs[a2] != nil && !st.archive.contains { $0.id == a2 } && st.validate().isEmpty, "restore brings the tab back")
st.closeTab(a2); st.purge(a2)
check(!st.archive.contains { $0.id == a2 } && st.tabs[a2] == nil, "purge is the only way a tab is really removed")
var solo = BrowserState(); let sp = solo.addSpace(name: "S", profile: prof1); let only = solo.addTab(in: sp, url: "https://x")!; let sw = solo.openWindow(space: sp)!
solo.closeTab(only); check(solo.windows[sw]!.selected == nil && solo.validate().isEmpty && solo.archive.count == 1, "closing last tab leaves window with no selection, tab archived")
check(solo.deleteSpace(sp) == nil, "cannot delete the only space")
let before = st.tabs.count + st.archive.count
let removed = st.deleteSpace(A)
check(removed != nil && st.windows.values.allSatisfy { $0.space != A } && st.validate().isEmpty, "delete space moves its windows elsewhere")
check(st.tabs.count + st.archive.count == before, "delete space archives its tabs: nothing lost")
let fromA = st.archive.filter { $0.space == A }
check(!fromA.isEmpty, "archive holds tabs from the deleted space")
if let a = fromA.first {
  let r = st.restoreTab(a.id)
  check({ if case .restored = r { return st.tabs[a.id]!.space != A && st.validate().isEmpty }; return false }(), "tab from deleted space restores into a surviving space of the SAME profile")
}
// review fix: restoring into a different profile needs confirmation (never leak identity)
var pr = BrowserState(); let pw = pr.addSpace(name: "Work", profile: prof1); let pp = pr.addSpace(name: "Personal", profile: prof2)
let pt = pr.addTab(in: pw, url: "https://work.example")!; pr.closeTab(pt)
_ = pr.deleteSpace(pw)   // work space (only prof1 space) is gone; only the personal profile remains
if case .needsProfileConfirmation(let f, let t) = pr.restoreTab(pt) { check(f == prof1 && t == prof2 && pr.archive.count == 1 && pr.tabs[pt] == nil, "restore into a different profile is refused until confirmed") } else { check(false, "restore into a different profile is refused until confirmed") }
check(pr.restoreTab(pt, confirmedCrossProfile: true) == .restored(pt) && pr.tabs[pt]?.space == pp && pr.validate().isEmpty, "confirmed cross-profile restore works")
// original lastActive survives close/restore
var lr = BrowserState(); let ls = lr.addSpace(name: "L", profile: prof1); let old = Date(timeIntervalSinceReferenceDate: 1234)
let lt = lr.addTab(in: ls, url: "u", now: old)!; lr.closeTab(lt); _ = lr.restoreTab(lt)
check(lr.tabs[lt]?.lastActive == old, "restore keeps the tab's original lastActive (LRU rank not reset)")

// 11. Fuzz: 5 seeds x 3000 ops, bounded windows, conservation + persistence inside the loop.
struct RNG { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) } }
func fuzz(seed: UInt64, store: Store?) -> String? {
  var rng = RNG(s: seed); var fz = BrowserState(); let fp = [ProfileID(), ProfileID()]
  for i in 0..<3 { fz.addSpace(name: "s\(i)", profile: fp[i % 2]) }
  var added = 0, purged = 0
  let titles = ["", "plain", "with \"quotes\" and 'single'", "unicode ☃ 日本語 🚀", "semi;colon -- comment", String(repeating: "x", count: 5000), "nul\u{0}byte"]
  for step in 0..<3000 {
    let sps = fz.spaces.map(\.id), tabsAll = Array(fz.tabs.keys), wins = Array(fz.windows.keys), arch = fz.archive.map(\.id)
    switch rng.next(11) {
    case 0, 1: if fz.addTab(in: sps[rng.next(sps.count)], url: "https://t\(step)/?q=\(titles[rng.next(titles.count)].count)", title: titles[rng.next(titles.count)], at: rng.next(5) - 1) != nil { added += 1 }
    case 2: if !tabsAll.isEmpty { fz.closeTab(tabsAll[rng.next(tabsAll.count)]) }
    case 3: if wins.count < 6 { _ = fz.openWindow(space: sps[rng.next(sps.count)]) }
    case 4: if wins.count > 1 { fz.closeWindow(wins[rng.next(wins.count)]) }
    case 5: if !wins.isEmpty && !tabsAll.isEmpty { _ = fz.select(tab: tabsAll[rng.next(tabsAll.count)], in: wins[rng.next(wins.count)]) }
    case 6: if !wins.isEmpty { fz.switchSpace(window: wins[rng.next(wins.count)], to: sps[rng.next(sps.count)]) }
    case 7: if !tabsAll.isEmpty { _ = fz.moveTab(tabsAll[rng.next(tabsAll.count)], to: sps[rng.next(sps.count)], confirmedCrossProfile: rng.next(2) == 0) }
    case 8: if !tabsAll.isEmpty && wins.count < 6 { _ = fz.detachTab(tabsAll[rng.next(tabsAll.count)]) }
    case 9: if !arch.isEmpty { if rng.next(3) == 0 { fz.purge(arch[rng.next(arch.count)]); purged += 1 } else { _ = fz.restoreTab(arch[rng.next(arch.count)], confirmedCrossProfile: rng.next(2) == 0) } }
    default: if rng.next(8) == 0 { _ = fz.deleteSpace(sps[rng.next(sps.count)]) } else if sps.count < 5 { fz.addSpace(name: "n\(step)", profile: fp[rng.next(2)]) }
    }
    let e = fz.validate(); if !e.isEmpty { return "seed \(seed) step \(step): \(e[0])" }
    if fz.tabs.count + fz.archive.count != added - purged { return "seed \(seed) step \(step): conservation broken (\(fz.tabs.count)+\(fz.archive.count) != \(added)-\(purged))" }
    if step % 150 == 0, let store {
      do { try store.save(fz); if try store.load() != fz { return "seed \(seed) step \(step): save/load mismatch" } } catch { return "seed \(seed) step \(step): store threw \(error)" }
    }
  }
  return nil
}
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("browser-checks", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
func tmpDB() -> String { dir.appendingPathComponent("\(UUID().uuidString).sqlite").path }
for seed in [42, 7, 1234, 99, 2026] as [UInt64] {
  guard let fstore = try? Store(path: tmpDB()) else { check(false, "fuzz seed \(seed): store opens"); continue }
  let r = fuzz(seed: seed, store: fstore)
  check(r == nil, "fuzz seed \(seed): 3000 ops, invariants + conservation + persistence round-trips \(r ?? "")")
}

// 12. Persistence
let path = tmpDB()
do {
  let store = try Store(path: path)
  check((try? store.load()) == BrowserState(), "fresh store loads empty state")
  var fz = BrowserState(); let sp1 = fz.addSpace(name: "Work", profile: prof1); let sp2 = fz.addSpace(name: "Home", profile: prof2)
  for i in 0..<30 { fz.addTab(in: i % 2 == 0 ? sp1 : sp2, url: "https://example.com/\(i)", title: "title \(i)") }
  let fw = fz.openWindow(space: sp1)!; _ = fw
  if let t = fz.tabs.keys.first { fz.closeTab(t) }
  try store.save(fz); check(try store.load() == fz, "save/load round trip incl. archive")
  var st2 = fz; if let t = st2.tabs.keys.first { st2.closeTab(t) }
  try store.save(st2); check(try store.load() == st2, "second save replaces first")
  let attrs = try FileManager.default.attributesOfItem(atPath: path)
  check(((attrs[.posixPermissions] as? Int) ?? 0) & 0o077 == 0, "database file is user-only (0600)")
  try store.simulateAbandonedTransaction()
  let reopened = try Store(path: path)
  check(try reopened.load() == st2, "abandoned transaction: last committed state intact")
  let cfgData = try JSONEncoder().encode(mine), usageData = try JSONEncoder().encode(usage)
  try reopened.setSetting("policy", cfgData); try reopened.setSetting("usage", usageData); try reopened.setSetting("policy", cfgData); try reopened.setSetting("empty", Data())
  let r2 = try Store(path: path)
  check(try JSONDecoder().decode(PolicyConfig.self, from: r2.setting("policy")!).defaultGrace == mine.defaultGrace, "policy settings persist across reopen")
  check(try JSONDecoder().decode(UsageModel.self, from: r2.setting("usage")!).expectedGap(host: "docs.example") == usage.expectedGap(host: "docs.example"), "usage model persists across reopen")
  check(try r2.setting("empty") == Data(), "empty blob setting round-trips")
  check(try r2.setting("missing") == nil, "missing setting is nil")
  // safety contract: existing DB must be loaded before save
  let r3 = try Store(path: path)
  do { try r3.save(BrowserState()); check(false, "save before load refused") } catch { check((error as? StoreError) == .mustLoadFirst, "save before load refused (cannot wipe sessions after a failed read)") }
  _ = try r3.load(); check((try? r3.save(st2)) != nil, "save allowed after a successful load")
} catch { check(false, "persistence block threw: \(error)") }
do {
  let s3 = try Store(path: tmpDB())
  let bad = BrowserState(spaces: [Space(name: "x", profile: prof1)], tabs: [TabRecord(space: SpaceID(), url: "u")], windows: [])
  do { try s3.save(bad); check(false, "invalid state refused") } catch { check(true, "invalid state refused") }
}
do {
  let vp = tmpDB(); var h: OpaquePointer?; sqlite3_open(vp, &h); sqlite3_exec(h, "PRAGMA user_version=99; CREATE TABLE t(x);", nil, nil, nil); sqlite3_close(h)
  do { _ = try Store(path: vp); check(false, "newer schema refused") } catch { check((error as? StoreError) == .schemaTooNew(99), "newer schema refused (no downgrade corruption)") }
  let gp = tmpDB(); try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: URL(fileURLWithPath: gp))
  do { _ = try Store(path: gp); check(false, "garbage file refused") } catch { check(true, "garbage file refused, not silently replaced") }
}
// migration v1 -> v2 keeps data
do {
  let mp = tmpDB(); var h: OpaquePointer?; sqlite3_open(mp, &h)
  let sid = UUID().uuidString, tid = UUID().uuidString, pid = UUID().uuidString
  let v1 = """
  CREATE TABLE space(id TEXT PRIMARY KEY, name TEXT NOT NULL, profile TEXT NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE tab(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, last_active REAL NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE window(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, selected TEXT, ord INTEGER NOT NULL);
  CREATE TABLE window_last(window TEXT NOT NULL REFERENCES window(id) ON DELETE CASCADE, space TEXT NOT NULL, tab TEXT NOT NULL, PRIMARY KEY(window, space));
  CREATE TABLE setting(key TEXT PRIMARY KEY, value BLOB NOT NULL);
  INSERT INTO space VALUES('\(sid)','Old','\(pid)',0); INSERT INTO tab VALUES('\(tid)','\(sid)','https://old.example','Old tab',0,1000.0,0);
  PRAGMA user_version=1;
  """
  sqlite3_exec(h, v1, nil, nil, nil); sqlite3_close(h)
  let ms = try Store(path: mp); let loaded = try ms.load()
  check(loaded.spaces.count == 1 && loaded.tabs.count == 1 && loaded.tabs.values.first?.url == "https://old.example" && loaded.archive.isEmpty, "migration v1 -> v2 preserves existing data")
  var back = loaded; back.closeTab(loaded.tabs.keys.first!); try ms.save(back)
  check(try Store(path: mp).load() == back, "migrated store accepts archive writes")
}

// 13. REAL crash safety: child process saves in a loop and is SIGKILLed mid-write; the DB must always load.
do {
  let cp = tmpDB(); do { let seed = try Store(path: cp); var s0 = BrowserState(); let sp0 = s0.addSpace(name: "seed", profile: prof1); s0.addTab(in: sp0, url: "https://seed"); try seed.save(s0) }
  var okRounds = 0, generations: [Int] = [], badExit = 0, walSeen = 0
  for round in 0..<14 {
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["--crash-writer", cp]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    usleep(UInt32(150_000 + (round * 53_000) % 450_000))
    kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
    if !(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL) { badExit += 1; print("  round \(round): child exited on its own (status \(child.terminationStatus)) — writer failed") }
    do {
      let l = try Store(path: cp).load()
      // must be exactly the seed OR exactly one complete committed generation (400 tabs, 1 window): never a mix
      let isSeed = l.spaces.count == 1 && l.spaces[0].name == "seed" && l.tabs.count == 1
      let gen = l.spaces.count == 1 && l.spaces[0].name.hasPrefix("g") ? Int(l.spaces[0].name.dropFirst()) : nil
      let isGen = gen != nil && l.tabs.count == 400 && l.windows.count == 1 && l.validate().isEmpty
      if isSeed || isGen { okRounds += 1 }; if let g = gen, isGen { generations.append(g) }
      if FileManager.default.fileExists(atPath: cp + "-wal") { walSeen += 1 }
    } catch { print("  crash round \(round) failed: \(error)") }
  }
  check(badExit == 0, "crash writer died only by SIGKILL (no silent failure inside the child)")
  check(okRounds == 14, "SIGKILL mid-write x14: DB always holds the seed or ONE complete generation (\(okRounds)/14)")
  check(generations.count >= 7 && (generations.max() ?? 0) >= 2, "the writer really wrote: \(generations.count) rounds saw a committed generation, max gen \(generations.max() ?? 0)")
  _ = walSeen
}

// 14. Quarantine, tab-state blobs, v2 -> v3 migration, WAL edge
do {
  let qp = tmpDB(); let qs = try Store(path: qp)
  var q = BrowserState(); let qsp = q.addSpace(name: "Q", profile: prof1); q.addTab(in: qsp, url: "https://q.example"); try qs.save(q)
  let dest = try qs.quarantineAndReset()
  check(FileManager.default.fileExists(atPath: dest), "quarantine preserved a copy of the database")
  check(try Store(path: dest).load() == q, "quarantined copy still holds the original sessions")
  check(try qs.load() == BrowserState() && (try? qs.save(q)) != nil, "after quarantine the live store is clean and writable")
  let blob = Data((0..<100_000).map { UInt8($0 % 251) }); let tid = TabID()
  try qs.setTabState(tid, blob); check(try qs.tabState(tid) == blob, "tab restore-state blob round-trips (100 KB)")
  try qs.setTabState(tid, nil); check(try qs.tabState(tid) == nil, "tab state can be cleared")
  try qs.setTabState(tid, blob); try qs.pruneTabStates(keeping: []); check(try qs.tabState(tid) == nil, "orphan tab states are pruned")
  // migration v2 -> v3
  let mp = tmpDB(); var h: OpaquePointer?; sqlite3_open(mp, &h)
  let sid = UUID().uuidString, tid2 = UUID().uuidString
  sqlite3_exec(h, """
  CREATE TABLE space(id TEXT PRIMARY KEY, name TEXT NOT NULL, profile TEXT NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE tab(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, last_active REAL NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE window(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, selected TEXT, ord INTEGER NOT NULL);
  CREATE TABLE window_last(window TEXT NOT NULL REFERENCES window(id) ON DELETE CASCADE, space TEXT NOT NULL, tab TEXT NOT NULL, PRIMARY KEY(window, space));
  CREATE TABLE setting(key TEXT PRIMARY KEY, value BLOB NOT NULL);
  CREATE TABLE archive(id TEXT PRIMARY KEY, space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, closed_at REAL NOT NULL, idx INTEGER NOT NULL, ord INTEGER NOT NULL);
  INSERT INTO space VALUES('\(sid)','S','\(UUID().uuidString)',0);
  INSERT INTO archive VALUES('\(tid2)','\(sid)','https://v2.example','V2 tab',0,500.0,0,0);
  PRAGMA user_version=2;
  """, nil, nil, nil); sqlite3_close(h)
  let m3 = try Store(path: mp).load()
  check(m3.archive.count == 1 && m3.archive[0].url == "https://v2.example" && m3.archive[0].profile == nil, "migration v2 -> v3 preserves archived tabs (profile unknown = nil)")
  // zero-length main file + non-empty WAL must NOT be treated as fresh
  let wp = tmpDB(); try Data().write(to: URL(fileURLWithPath: wp)); try Data(repeating: 1, count: 64).write(to: URL(fileURLWithPath: wp + "-wal"))
  if let ws = try? Store(path: wp) {
    do { try ws.save(BrowserState()); check(false, "zero-length db + WAL: save must be refused until loaded") }
    catch { check((error as? StoreError) == .mustLoadFirst, "zero-length db + non-empty WAL is not 'fresh': save refused until loaded") }
  } else { check(true, "zero-length db with non-empty WAL refused to open (safe)") }
}

// 15. Usage recorder: opt-in, hashed, private, bounded
do {
  let up = tmpDB() + ".usage"
  let off = try UsageRecorder(path: up, enabled: false)
  off.recordActivation(tab: TabID(), host: "secret.example")
  check(!FileManager.default.fileExists(atPath: up), "recorder disabled by default: writes nothing")
  let on = try UsageRecorder(path: up, enabled: true)
  let tA = TabID(), tB = TabID()
  for i in 0..<5 { on.recordActivation(tab: i % 2 == 0 ? tA : tB, host: "bank.example", at: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 60)) }
  let txt = try String(contentsOfFile: up, encoding: .utf8)
  check(!txt.contains("bank.example") && !txt.contains(tA.raw.uuidString), "recorder file contains no plaintext host or tab id")
  let ev = UsageRecorder.parse(txt)
  check(ev.count == 5 && ev[0].host == ev[1].host && ev[0].tab == ev[2].tab && ev[0].tab != ev[1].tab, "recorder events round-trip with stable hashes")
  check((((try FileManager.default.attributesOfItem(atPath: up))[.posixPermissions] as? Int) ?? 0) & 0o077 == 0, "recorder file is user-only (0600)")
  let again = try UsageRecorder(path: up, enabled: true)
  again.recordActivation(tab: tA, host: "bank.example", at: Date(timeIntervalSince1970: 2_000_000))
  let ev2 = UsageRecorder.parse(try String(contentsOfFile: up, encoding: .utf8))
  check(ev2.count == 6 && ev2.last?.host == ev2[0].host, "salt persists across reopen (hashes stay comparable)")
  let rp = tmpDB() + ".usage2"
  let small = try UsageRecorder(path: rp, enabled: true, maxBytes: 600)
  for i in 0..<200 { small.recordActivation(tab: tA, host: "h\(i % 7)", at: Date(timeIntervalSince1970: 1000 + Double(i))) }
  let rtxt = try String(contentsOfFile: rp, encoding: .utf8); let rsize = rtxt.utf8.count
  let revs = UsageRecorder.parse(rtxt)
  check(rsize <= 600 + 60 && rtxt.hasPrefix("#v1 salt="), "recorder rotation keeps the file bounded (\(rsize) bytes) and keeps the header")
  check(revs.last?.time == Date(timeIntervalSince1970: 1199) && revs.count > 5 && revs.count < 200, "rotation keeps the NEWEST records (\(revs.count) kept)")
  check(UsageRecorder.parse("garbage\n1,2\nx,y,z\n5,aa,bb\n").count == 1, "parser skips malformed lines")
  // review fixes: never overwrite an unreadable log; recreate with the SAME salt if the file vanished (moved, not deleted)
  let badLog = tmpDB() + ".usage3"; try Data("not a header\n1,2,3\n".utf8).write(to: URL(fileURLWithPath: badLog))
  do { _ = try UsageRecorder(path: badLog, enabled: true); check(false, "unreadable usage log refused") } catch { check(true, "unreadable usage log is refused, not overwritten") }
  check((try? String(contentsOfFile: badLog, encoding: .utf8))?.contains("not a header") == true, "refused log content untouched")
  let mvPath = tmpDB() + ".usage4"; let mv = try UsageRecorder(path: mvPath, enabled: true); let sameTab = TabID()
  mv.recordActivation(tab: sameTab, host: "x.example", at: Date(timeIntervalSince1970: 10))
  try FileManager.default.moveItem(atPath: mvPath, toPath: mvPath + ".moved")
  mv.recordActivation(tab: sameTab, host: "x.example", at: Date(timeIntervalSince1970: 20))
  let a1 = UsageRecorder.parse(try String(contentsOfFile: mvPath + ".moved", encoding: .utf8)), a2 = UsageRecorder.parse(try String(contentsOfFile: mvPath, encoding: .utf8))
  check(a1.count == 1 && a2.count == 1 && a1[0].host == a2[0].host && a1[0].tab == a2[0].tab, "recording continues after the file vanished, with the same salt")
  check((((try FileManager.default.attributesOfItem(atPath: mvPath))[.posixPermissions] as? Int) ?? 0) & 0o077 == 0, "recreated usage log is 0600")
}
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
