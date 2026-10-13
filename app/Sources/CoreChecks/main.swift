import BrowserCore
import Foundation
import Lifecycle
import Persistence
import ContentBlocking
import EngineCore
import Extensions
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
// 16. LifecycleManager (engine-agnostic orchestration) with fake tabs
@MainActor final class FakeTab: EngineTab {
  let id = TabID(); var live = true; var isActive = false; var sig = TabSignals(); var delayMs = 0; var hibernations = 0; var wasResumed = 0
  var isLive: Bool { live }
  var mem: UInt64?; var shed = 0; var dirty = false
  var hasUnsavedInput: Bool { dirty }
  var memoryBytes: UInt64? { mem }
  func shedForMemory(bytes: UInt64) { shed += 1; live = false; mem = nil }
  func signals(timeout: TimeInterval) async -> TabSignals {
    if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
    return sig
  }
  @discardableResult func hibernate(force: Bool) -> Bool { if isActive && !force { return false }; if !live { return false }; live = false; hibernations += 1; return true }
  @discardableResult func ensureLiveView() -> Bool { let was = !live; live = true; if was { wasResumed += 1 }; return was }
  func captureState() -> Data? { nil }
  var currentURL: URL? { nil }
  var currentTitle: String? { nil }
  var onChange: (() -> Void)?
  var canGoBack: Bool { false }
  var canGoForward: Bool { false }
  var isLoadingPage: Bool { false }
  var progress: Double { 0 }
  func load(_ url: URL) { loaded.append(url) }
  var loaded: [URL] = []
  func goBack() {}
  func goForward() {}
  func reload() {}
  func stopLoading() {}
}
do {
  @MainActor func world(pressure: @escaping () -> PressureLevel = { .normal }, config: PolicyConfig = .relaxed) -> (LifecycleManager, () -> Date, (TimeInterval) -> Void) {
    nonisolated(unsafe) var clockNow = Date(timeIntervalSince1970: 5_000_000)
    let m = LifecycleManager(config: config, clock: { clockNow }, pressure: pressure)
    return (m, { clockNow }, { clockNow = clockNow.addingTimeInterval($0) })
  }
  let (m1, _, adv1) = world()
  let t1 = (0..<4).map { _ in FakeTab() }
  for (i, t) in t1.enumerated() { m1.register(t, host: "site\(i).example") }
  adv1(3 * 3600)
  m1.activate(t1[0].id)
  t1[1].sig.hasDirtyForm = true; t1[2].sig.isPlayingMedia = true
  let r1 = await m1.pass()
  check(r1.hibernated == [t1[3].id] && t1[0].live && t1[1].live && t1[2].live && !t1[3].live, "manager: hibernates only the idle unprotected tab (active, dirty form, playing media kept)")
  check(r1.protected[t1[1].id] == [.unsavedForm] && r1.protected[t1[2].id] == [.playingMedia] && r1.protected[t1[0].id] == [.active], "manager: reports WHY each tab was kept")

  // user switches tab while signals are still being gathered: the freshest isActive wins
  let (m2, _, adv2) = world()
  let slow = FakeTab(), other = FakeTab(), idle3 = FakeTab(); slow.delayMs = 250
  m2.register(slow, host: "slow.example"); m2.register(other, host: "other.example"); m2.register(idle3, host: "idle.example"); adv2(5 * 3600)
  m2.activate(other.id)
  let passTask = Task { @MainActor in await m2.pass() }
  try? await Task.sleep(nanoseconds: 80_000_000)
  m2.activate(slow.id)                                 // user switches to the slow tab mid-pass
  let r2 = await passTask.value
  check(slow.live && slow.hibernations == 0 && other.live && r2.hibernated == [idle3.id], "manager: tab the user switched to mid-pass is NOT hibernated, the one just left is fresh, only the idle tab goes")

  // hung tab: shedding allowed and reported
  let (m3, _, adv3) = world(); let hung = FakeTab(), live3 = FakeTab(); hung.sig.isUnresponsive = true
  m3.register(hung, host: "hung.example"); m3.register(live3, host: "ok.example"); adv3(5 * 3600); m3.activate(live3.id)
  let r3 = await m3.pass()
  check(r3.unresponsive == [hung.id] && !hung.live, "manager: a hung (unresponsive) tab is reported and may be hibernated")

  // habit learning through activation
  let (m4, _, adv4) = world(); let ha = FakeTab(), hb = FakeTab()
  m4.register(ha, host: "docs.example"); m4.register(hb, host: "mail.example")
  m4.activate(ha.id); adv4(60); m4.activate(hb.id); adv4(20 * 60); m4.activate(ha.id)
  check(abs((m4.usage.expectedGap(host: "docs.example") ?? 0) - 20 * 60) < 1, "manager: learns the idle gap between leaving a tab and returning to it (20 min)")
  check(m4.activeTab == ha.id && ha.isActive && !hb.isActive, "manager: exactly one active tab")

  // hibernated tab is resumed on activate
  let (m5, _, adv5) = world(); let cold = FakeTab(), foc = FakeTab()
  m5.register(cold, host: "c.example"); m5.register(foc, host: "f.example"); adv5(5 * 3600); m5.activate(foc.id); _ = await m5.pass()
  check(!cold.live, "setup: cold tab hibernated")
  m5.activate(cold.id); check(cold.live && cold.wasResumed == 1 && cold.isActive, "manager: activating a hibernated tab resumes it")

  // pressure changes the outcome; sleep/wake does not mass-hibernate
  nonisolated(unsafe) var lvl = PressureLevel.normal
  var neutral = PolicyConfig(); neutral.maxLive = .init(normal: 100, warning: 100, critical: 100)
  let (m6, _, adv6) = world(pressure: { lvl }, config: neutral); let p6 = FakeTab(), p6b = FakeTab()
  m6.register(p6, host: "p.example"); m6.register(p6b, host: "q.example"); adv6(20 * 60); m6.activate(p6b.id)
  let calm = await m6.pass(); check(calm.hibernated.isEmpty, "manager: 20 min idle is fine at normal pressure")
  lvl = .critical; let tight = await m6.pass(); check(tight.hibernated == [p6.id], "manager: same tab is released at critical pressure")
  let (m7, _, adv7) = world(); let w1 = FakeTab(), w2 = FakeTab(); m7.register(w1, host: "w.example"); m7.register(w2, host: "z.example")
  adv7(10 * 3600); m7.noteWake(); m7.activate(w2.id); let rw = await m7.pass()
  check(rw.hibernated.isEmpty && w1.live, "manager: after a wake from sleep nothing is hibernated for being 'idle' across the sleep")

  // unregister while awaiting signals must not crash
  let (m8, _, adv8) = world(); let u1 = FakeTab(), u2 = FakeTab(); u1.delayMs = 150; m8.register(u1, host: "u1"); m8.register(u2, host: "u2"); adv8(5 * 3600); m8.activate(u2.id)
  let pt = Task { @MainActor in await m8.pass() }; try? await Task.sleep(nanoseconds: 40_000_000); m8.unregister(u1.id); _ = await pt.value
  check(m8.liveCount == 1, "manager: unregistering a tab mid-pass is safe")
}
// 17. SessionManager: recovery order, debounce, backup ring
do {
  func fresh(_ n: Int) -> BrowserState { var s = BrowserState(); let sp = s.addSpace(name: "S\(n)", profile: ProfileID()); for i in 0..<n { s.addTab(in: sp, url: "https://x.example/\(i)") }; return s }
  // clean start, save, backup ring rotates through slots
  let sp = tmpDB(); let s5 = fresh(5)
  do {   // scoped: the first "process" must exit (close its connection) before the file is damaged, like a real crash + relaunch
    let (mgr, st0, rec0) = try SessionManager.start(path: sp)
    check(rec0 == .clean && st0 == BrowserState(), "session: first launch is clean and empty")
    try mgr.save(s5)
    let slots = try (0..<4).map { _ in try mgr.rotateBackup() }
    check(slots == [0, 1, 2, 0], "session: backup ring cycles through 3 slots in place (\(slots))")
  }
  // main DB turned to garbage (overwritten in place), backup exists: recover from backup
  try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: URL(fileURLWithPath: sp))
  for sfx in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: sp + sfx) { try Data().write(to: URL(fileURLWithPath: sp + sfx)) }
  let (mgr2, st2, rec2) = try SessionManager.start(path: sp)
  if case .restoredFromBackup = rec2 { check(st2 == s5, "session: corrupt main restored from the newest valid backup (\(st2.tabs.count) tabs)") } else { check(false, "session: corrupt main restored from backup (got \(rec2))") }
  check((try? mgr2.save(fresh(7))) != nil && ((try? Store(path: sp).load())?.tabs.count == 7), "session: recovered store is writable and durable")
  // corrupt main and NO backup: quarantine keeps the bytes, starts clean
  let np = tmpDB(); let garbage = Data((0..<1024).map { _ in UInt8.random(in: 0...255) }); try garbage.write(to: URL(fileURLWithPath: np))
  let (mgr3, st3, rec3) = try SessionManager.start(path: np)
  if case .quarantined(let qp) = rec3 { check(st3 == BrowserState() && (try? Data(contentsOf: URL(fileURLWithPath: qp))) == garbage, "session: unrecoverable main is quarantined byte-for-byte and the app starts clean") } else { check(false, "session: unrecoverable main is quarantined (got \(rec3))") }
  check((try? mgr3.save(fresh(2))) != nil, "session: clean store after quarantine accepts saves")
  // debounce coalesces bursts into one write; flush writes immediately
  let dp = tmpDB(); let (mgr4, _, _) = try SessionManager.start(path: dp, debounce: 0.2)
  for n in 1...5 { mgr4.scheduleSave(fresh(n)) }
  check((try? Store(path: dp).load()) == BrowserState(), "session: nothing written before the debounce window")
  try await Task.sleep(nanoseconds: 450_000_000)
  check((try? Store(path: dp).load().tabs.count) == 5, "session: burst of 5 scheduled saves coalesced into one (the last state, 5 tabs)")
  mgr4.scheduleSave(fresh(9)); try mgr4.flush(); check((try? Store(path: dp).load().tabs.count) == 9, "session: flush() writes the pending state immediately")
  // tab state blobs through the manager
  let tid = TabID(); let blob = Data("history+scroll".utf8)
  mgr4.persistTabState(tid, blob); check(mgr4.tabState(tid) == blob, "session: tab restore state persists")
}
// 18. BrowserEngine facade over fake tabs
@MainActor final class FTab: EngineTab {
  let id: TabID; var live = false; var isActive = false; var sig = TabSignals(); var restored: Data?; var state: Data?; var hibernations = 0; var url: URL?
  init(id: TabID, url: URL?, restored: Data?) { self.id = id; self.url = url; self.restored = restored; self.state = restored }
  var isLive: Bool { live }
  func signals(timeout: TimeInterval) async -> TabSignals { sig }
  @discardableResult func hibernate(force: Bool) -> Bool { if !live { return false }; if isActive && !force { return false }; live = false; hibernations += 1; return true }
  @discardableResult func ensureLiveView() -> Bool { let was = !live; live = true; return was }
  func captureState() -> Data? { state }
  var currentURL: URL? { url }
  var title: String?
  var currentTitle: String? { title }
  var onChange: (() -> Void)?
  var canGoBack: Bool { false }
  var canGoForward: Bool { false }
  var isLoadingPage: Bool { false }
  var progress: Double { 0 }
  func load(_ url: URL) { loaded.append(url) }
  var loaded: [URL] = []
  func goBack() {}
  func goForward() {}
  func reload() {}
  func stopLoading() {}
}
@MainActor final class FFactory: TabFactory {
  var linkOpenHandler: ((TabID, URL) -> Void)?
  var closeRequestHandler: ((TabID) -> Void)?
  var made: [TabID: FTab] = [:]; var creations = 0; var profiles: [TabID: [ProfileID]] = [:]
  func makeTab(id: TabID, url: URL?, profile: ProfileID, restoredState: Data?) -> any EngineTab { creations += 1; let t = FTab(id: id, url: url, restored: restoredState); made[id] = t; profiles[id, default: []].append(profile); return t }
}
do {
  let ep = tmpDB(); let (sess, st0, _) = try SessionManager.start(path: ep, debounce: 0.05)
  let ff = FFactory(); var clockNow = Date(timeIntervalSince1970: 9_000_000)
  let life = LifecycleManager(config: .relaxed, clock: { clockNow })
  let eng = BrowserEngine(session: sess, state: st0, factory: ff, lifecycle: life)
  let pf = ProfileID(); let spA = eng.addSpace(name: "Work", profile: pf), spB = eng.addSpace(name: "Home", profile: pf)
  let w1 = eng.openWindow(space: spA)!
  let tA = eng.newTab(in: spA, url: "https://a.example/1", window: w1)!, tB = eng.newTab(in: spA, url: "https://b.example/2")!, tC = eng.newTab(in: spB, url: "https://c.example/3")!
  check(ff.creations == 3 && ff.made[tA]!.live && !ff.made[tB]!.live && !ff.made[tC]!.live, "engine: new tabs are hibernated; the one selected in a window is live")
  check(eng.state.validate().isEmpty && eng.liveCount == 1, "engine: model valid, 1 live tab")

  // closing a tab archives it, saves its restore state, tears down the engine tab
  ff.made[tB]!.state = Data("history-of-B".utf8); ff.made[tB]!.live = true
  eng.closeTab(tB)
  check(eng.state.tabs[tB] == nil && eng.state.archive.contains { $0.id == tB } && eng.tab(tB) == nil && !ff.made[tB]!.live, "engine: close sleeps the tab into the archive and tears down its view")
  check(sess.tabState(tB) == Data("history-of-B".utf8), "engine: closing saved the tab's restore state")
  let r = eng.restoreTab(tB)
  if case .restored(let nid) = r { check(nid == tB && eng.tab(tB) != nil && ff.made[tB]!.restored == Data("history-of-B".utf8), "engine: restoring recreates the tab WITH its saved history") } else { check(false, "engine: restore (got \(r))") }

  // closing a window never closes tabs; sleeps them unless protected
  let w2 = eng.openWindow(space: spB)!; _ = eng.select(tab: tC, in: w2)
  ff.made[tC]!.sig.isPlayingMedia = true
  eng.closeWindow(w2); try await Task.sleep(nanoseconds: 120_000_000)
  check(eng.state.tabs[tC] != nil && ff.made[tC]!.live, "engine: closing a window keeps its tab, and a tab PLAYING MEDIA keeps playing")
  ff.made[tC]!.sig.isPlayingMedia = false
  let w3 = eng.openWindow(space: spB)!; _ = eng.select(tab: tC, in: w3); eng.closeWindow(w3); try await Task.sleep(nanoseconds: 120_000_000)
  check(!ff.made[tC]!.live && eng.state.tabs[tC] != nil, "engine: closing a window sleeps its idle tab immediately (tab kept)")

  // two windows: both visible tabs protected from the lifecycle pass; detach creates a second visible tab
  _ = eng.select(tab: tB, in: w1)
  let w4 = eng.detachTab(tA)!
  check(eng.state.visibleTabs == [tA, tB] || eng.state.visibleTabs.contains(tA), "engine: detach opens a second window showing the tab")
  clockNow = clockNow.addingTimeInterval(10 * 3600)
  let rep = await eng.maintenance()
  check(ff.made[tA]!.live && !rep.hibernated.contains(tA) && !rep.hibernated.contains(eng.state.windows[w1]?.selected ?? tA), "engine: tabs visible in ANY window survive a maintenance pass")
  check(rep.hibernated.contains(tC) == false, "engine: already-sleeping tab is not re-hibernated")
  _ = w4

  // deleting a space archives its tabs and tears down their engine tabs
  let before = eng.state.tabs.count + eng.state.archive.count
  _ = eng.deleteSpace(spB)
  check(eng.state.tabs.count + eng.state.archive.count == before && eng.tab(tC) == nil && !ff.made[tC]!.live, "engine: deleting a space archives its tabs, nothing lost, engine tab torn down")

  // restart: persisted session comes back lazily
  try eng.shutdown()
  let (sess2, st2, rec2) = try SessionManager.start(path: ep)
  let ff2 = FFactory(); let eng2 = BrowserEngine(session: sess2, state: st2, factory: ff2, lifecycle: LifecycleManager(config: .relaxed))
  check(rec2 == .clean && st2 == eng.state, "engine: session round-trips exactly across a restart")
  let selected = Set(st2.windows.values.compactMap(\.selected))
  check(ff2.made.count == st2.tabs.count && ff2.made.values.filter { $0.live }.count == selected.count && ff2.made.values.filter { $0.live }.allSatisfy { selected.contains($0.id) }, "engine: restart is LAZY: \(ff2.made.count) tabs created, only the \(selected.count) window-selected ones live")
  _ = eng2
}
// 19. Review fixes (4th review): transient != corruption, blobs survive backup restore, retries, profile move, syncing
do {
  func fresh2(_ n: Int) -> BrowserState { var s = BrowserState(); let sp = s.addSpace(name: "R\(n)", profile: ProfileID()); for i in 0..<n { s.addTab(in: sp, url: "https://r.example/\(i)") }; return s }
  // HIGH 1: a busy database must NEVER be truncated/recovered; newer schema must not be touched either
  let bp = tmpDB(); do { let (m, _, _) = try SessionManager.start(path: bp); try m.save(fresh2(4)) }
  let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: bp))
  var lockH: OpaquePointer?; sqlite3_open(bp, &lockH); sqlite3_exec(lockH, "BEGIN IMMEDIATE", nil, nil, nil)   // another process holds the write lock
  do { _ = try SessionManager.start(path: bp); check(false, "busy database: start() must throw") } catch { check((error as? StoreError).map { if case .busy = $0 { return true }; return false } ?? false, "busy database: start() throws .busy instead of recovering") }
  sqlite3_exec(lockH, "ROLLBACK", nil, nil, nil); sqlite3_close(lockH)
  check(try Data(contentsOf: URL(fileURLWithPath: bp)) == beforeBytes || ((try? Store(path: bp).load().tabs.count) == 4), "busy database: the healthy DB was NOT truncated (4 tabs intact)")
  let (mAfter, sAfter, rAfter) = try SessionManager.start(path: bp); _ = mAfter
  check(rAfter == .clean && sAfter.tabs.count == 4, "busy database: after the lock is released the session loads normally")
  let tp = tmpDB(); var th: OpaquePointer?; sqlite3_open(tp, &th); sqlite3_exec(th, "PRAGMA user_version=99; CREATE TABLE t(x);", nil, nil, nil); sqlite3_close(th)
  let tooNewBefore = try Data(contentsOf: URL(fileURLWithPath: tp))
  do { _ = try SessionManager.start(path: tp); check(false, "newer schema: start() must throw") } catch { check((error as? StoreError) == .schemaTooNew(99), "newer schema: start() throws and does not recover") }
  check(try Data(contentsOf: URL(fileURLWithPath: tp)) == tooNewBefore, "newer schema: file untouched (downgrade cannot destroy data)")

  // HIGH 2: restore from backup keeps the tab restore-state blobs; reports backup age
  let rp = tmpDB(); let blobTab = TabID(); let blob = Data("deep history".utf8)
  do { let (m, _, _) = try SessionManager.start(path: rp); let st = fresh2(3); try m.save(st); m.persistTabState(blobTab, blob); _ = try m.rotateBackup() }
  try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: URL(fileURLWithPath: rp))
  for sfx in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: rp + sfx) { try Data().write(to: URL(fileURLWithPath: rp + sfx)) }
  let (mr, sr, rr) = try SessionManager.start(path: rp)
  if case .restoredFromBackup(_, let age) = rr { check(sr.tabs.count == 3 && mr.tabState(blobTab) == blob && age >= 0 && age < 60, "restore from backup keeps tab restore blobs and reports the backup age (\(Int(age)) s)") } else { check(false, "restore from backup (got \(rr))") }

  // MEDIUM: failed saves are retried; failed blob writes are queued
  let fp = tmpDB(); let (mf, _, _) = try SessionManager.start(path: fp, debounce: 0.05); mf.retryBase = 0.05
  var failures2 = 0; mf.onSaveFailure = { _ in failures2 += 1 }
  mf.store._failWrites = 2; mf.scheduleSave(fresh2(6))
  try await Task.sleep(nanoseconds: 700_000_000)
  check(failures2 == 2 && mf.lastSaveError == nil && (try? Store(path: fp).load().tabs.count) == 6, "save failures are reported and RETRIED until the state is written (\(failures2) failures, then success)")
  let qt = TabID(); mf.store._failWrites = 1; mf.persistTabState(qt, Data("q".utf8))
  check(mf.tabState(qt) == Data("q".utf8), "failed blob write is queued and still readable")
  try mf.flush(); check((try? Store(path: fp).tabState(qt)) == Data("q".utf8), "queued blob is written on the next flush")
  mf.store._failReads = 1; let rf = mf.tabStateResult(qt); check(rf.failed && rf.data == nil, "a failed blob READ is flagged, not reported as 'no history'")

  // MEDIUM: engine syncs live URL/title; profile move rebuilds under the new data store; unreadable blob never overwritten
  let sp2 = tmpDB(); let (se, s0, _) = try SessionManager.start(path: sp2, debounce: 0.05)
  let f2 = FFactory(); let e2 = BrowserEngine(session: se, state: s0, factory: f2)
  let pW = ProfileID(), pP = ProfileID(); let spW = e2.addSpace(name: "W", profile: pW), spP = e2.addSpace(name: "P", profile: pP)
  let wnd = e2.openWindow(space: spW)!; let tt = e2.newTab(in: spW, url: "https://start.example", window: wnd)!
  f2.made[tt]!.url = URL(string: "https://navigated.example/page"); f2.made[tt]!.title = "Navigated"; f2.made[tt]!.state = Data("hist-W".utf8)
  try e2.shutdown()
  check(e2.state.tabs[tt]?.url == "https://navigated.example/page" && e2.state.tabs[tt]?.title == "Navigated", "engine writes the live URL and title back into the saved model")
  if case .needsProfileConfirmation = e2.moveTab(tt, to: spP) { check(f2.profiles[tt]?.count == 1, "cross-profile move without confirmation changes nothing") } else { check(false, "cross-profile move needs confirmation") }
  _ = e2.moveTab(tt, to: spP, confirmedCrossProfile: true)
  check(f2.profiles[tt] == [pW, pP], "after a confirmed cross-profile move the tab is REBUILT under the destination profile's data store")
  check(f2.made[tt]!.restored == Data("hist-W".utf8), "profile move carries the tab's history across")
  let orphanSp = tmpDB(); let (so, _, _) = try SessionManager.start(path: orphanSp); let pu = ProfileID(); let ub = TabID(); so.persistTabState(ub, Data("precious".utf8))
  var os2 = BrowserState(); let osp = os2.addSpace(name: "O", profile: pu); let otid = os2.addTab(in: osp, url: "https://o.example")!
  _ = ub; so.persistTabState(otid, Data("precious".utf8)); so.store._failReads = 1
  let f3 = FFactory(); let e3 = BrowserEngine(session: so, state: os2, factory: f3); f3.made[otid]!.state = Data("short".utf8)
  try e3.shutdown(); check((try? so.store.tabState(otid)) == Data("precious".utf8), "unreadable saved history is never overwritten by a shorter one")
}
// 20. LifecycleManager: stamps on leaving visibility; sleepNow refuses unresponsive tabs
do {
  nonisolated(unsafe) var cn = Date(timeIntervalSince1970: 7_000_000)
  let mg = LifecycleManager(config: .relaxed, clock: { cn })
  let vt = FakeTab(), other2 = FakeTab(); mg.register(vt, host: "v.example"); mg.register(other2, host: "o.example")
  mg.setVisible([vt.id]); cn = cn.addingTimeInterval(3 * 3600)           // shown for 3 hours
  mg.setVisible([other2.id])                                              // switched space: vt is no longer shown
  let rv = await mg.pass()
  check(vt.live && !rv.hibernated.contains(vt.id), "tab shown for hours is NOT hibernated the moment it leaves the screen (idle clock starts then)")
  let hu = FakeTab(); hu.sig.isUnresponsive = true; mg.register(hu, host: "h.example"); mg.setVisible([other2.id])
  let slept = await mg.sleepNow(hu.id)
  check(!slept && hu.live, "sleepNow refuses an unresponsive tab (cannot tell if media is playing)")
}
// 21. URL input + navigation policy
do {
  func r(_ s: String) -> String? { URLInput.resolve(s)?.absoluteString }
  check(r("example.com") == "https://example.com", "input: bare domain -> https")
  check(r("  https://example.com/a?b=c  ") == "https://example.com/a?b=c", "input: explicit https kept, trimmed")
  check(r("http://example.com") == "http://example.com", "input: explicit http kept")
  check(r("localhost:3000") == "http://localhost:3000", "input: localhost:port -> http (host:port is not a scheme)")
  check(r("127.0.0.1:8080/x") == "http://127.0.0.1:8080/x", "input: IPv4 -> http")
  check(r("192.168.1.1") == "http://192.168.1.1", "input: LAN IP -> http")
  check(r("example.com:8080/path") == "https://example.com:8080/path", "input: domain:port -> https")
  check(r("sub.example.co.uk/path?q=1#f") == "https://sub.example.co.uk/path?q=1#f", "input: deep domain path query fragment")
  check(r("javascript:alert(1)") == nil, "input: javascript: refused")
  check(r("JaVaScRiPt:alert(1)") == nil, "input: javascript: refused case-insensitively")
  check(r("data:text/html,<script>alert(1)</script>") == nil, "input: data: refused")
  check(r("file:///etc/passwd") == nil, "input: file: refused")
  check(r("view-source:https://example.com") == nil, "input: view-source: refused")
  check(r("mailto:a@b.com") == nil, "input: mailto: typed in the address bar refused")
  check(r("ftp://example.com") == nil, "input: ftp refused")
  check(r("about:blank") == "about:blank", "input: about:blank allowed")
  check(r("about:config") == nil, "input: other about: pages refused")
  check(r("swift concurrency") == "https://duckduckgo.com/?q=swift%20concurrency", "input: words -> search")
  check(r("what is 3.14") == "https://duckduckgo.com/?q=what%20is%203.14", "input: sentence with a number -> search")
  check(r("3.14") != nil && !(r("3.14")?.contains("3.14/") ?? false) && r("3.14")?.hasPrefix("https://duckduckgo.com") == true, "input: 3.14 is a number, not a host -> search")
  check(r("a&b=c#d") == "https://duckduckgo.com/?q=a%26b%3Dc%23d", "input: search query is fully encoded (no parameter injection)")
  check(r("user@example.com") == "https://duckduckgo.com/?q=user@example.com" || r("user@example.com")?.hasPrefix("https://duckduckgo.com") == true, "input: email-like -> search, not userinfo URL")
  check(r("https://user:pass@evil.com@good.com") != nil, "input: odd authority still parsed by URL, policy decides later")
  check(r("") == nil && r("   ") == nil, "input: empty refused")
  check(r("a\nb.com") == nil && r("exa\u{0}mple.com") == nil, "input: control characters / newlines refused")
  check(r(String(repeating: "a", count: 9000)) == nil, "input: oversized input refused")
  check(r("//evil.com/path")?.hasPrefix("https://duckduckgo.com") == true, "input: protocol-relative is text, not a navigation")
  check(URLInput.resolve("hello world", searchTemplate: "https://search.example/?q=%s")?.absoluteString == "https://search.example/?q=hello%20world", "input: custom search engine template")
  // navigation policy
  func d(_ u: String, click: Bool = false, main: Bool = true) -> NavigationDecision { NavigationPolicy.decide(url: URL(string: u), userInitiated: click, isMainFrame: main) }
  check(d("https://a.example") == .allow && d("http://a.example") == .allow, "policy: http(s) allowed")
  check(d("javascript:alert(1)", click: true) != .allow && d("file:///etc/hosts", click: true) != .allow, "policy: javascript: and file: blocked even on click")
  check(d("data:text/html,x") != .allow && d("data:text/html,x", main: false) == .allow, "policy: data: blocked top-level, allowed in subframes")
  check(d("mailto:a@b.com") != .openExternally && d("mailto:a@b.com", click: true) == .openExternally, "policy: mailto: launches an app only after a real click")
  check(d("zoommtg://x", main: false, ) != .openExternally && d("zoommtg://x", click: true, main: false) != .openExternally, "policy: subframes can never launch apps")
  check(d("about:blank") == .allow && d("about:config") != .allow, "policy: about:blank only")
  check(NavigationPolicy.decide(url: nil, userInitiated: true, isMainFrame: true) != .allow, "policy: nil URL blocked")
  check(d("ftp://x.example", click: true) != .allow && d("view-source:https://x.example", click: true) != .allow, "policy: ftp / view-source blocked")
}
// 22. Error page + download names
do {
  check(DownloadNames.sanitize("../../etc/passwd") == "_.._etc_passwd" || !DownloadNames.sanitize("../../etc/passwd").contains("/"), "download name: path traversal neutralised")
  check(DownloadNames.sanitize(".bashrc") == "bashrc" && DownloadNames.sanitize("...hidden") == "hidden", "download name: no leading dots (no hidden files)")
  check(DownloadNames.sanitize("a\u{0}b\nc.txt") == "abc.txt", "download name: control characters stripped")
  check(DownloadNames.sanitize("   ") == "download" && DownloadNames.sanitize("") == "download", "download name: empty becomes 'download'")
  check(DownloadNames.sanitize(String(repeating: "x", count: 500)).count == 120, "download name: length bounded")
  check(DownloadNames.sanitize("C:\\win\\evil.exe") == "C__win_evil.exe", "download name: backslashes and colons replaced")
  var taken: Set<String> = ["a.zip", "a 2.zip"]
  check(DownloadNames.unique("a.zip", exists: { taken.contains($0) }) == "a 3.zip", "download name: never overwrites (a 3.zip)")
  taken = ["noext"]; check(DownloadNames.unique("noext", exists: { taken.contains($0) }) == "noext 2", "download name: no extension case")
  let h = ErrorPage.html(url: "https://x.example/?a=<script>alert(1)</script>", title: "T<b>", message: "m\"'&", code: -1200)
  check(!h.contains("<script>alert") && h.contains("&lt;script&gt;") && !h.contains("<b>") && h.contains("&quot;") && h.contains("Content-Security-Policy"), "error page: everything escaped, CSP blocks scripts")
  let cert = ErrorPage.describe(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
  check(cert.isCertificate && cert.message.contains("no way to continue"), "error page: untrusted certificate has no bypass wording")
  check(ErrorPage.describe(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet).title == "You're offline", "error page: offline message")
  check(!ErrorPage.describe(domain: "Other", code: 1).isCertificate, "error page: unknown errors are generic")
}
// 23. Engine navigation API
do {
  let np = tmpDB(); let (sn, s0, _) = try SessionManager.start(path: np, debounce: 0.05)
  let ff = FFactory(); let en = BrowserEngine(session: sn, state: s0, factory: ff)
  let sp = en.addSpace(name: "N", profile: ProfileID()); let wd = en.openWindow(space: sp)!
  let t1 = en.newTab(in: sp, url: "https://start.example", window: wd)!
  check(en.navigate(tab: t1, input: "example.com") && ff.made[t1]!.loaded == [URL(string: "https://example.com")!], "engine.navigate: typed domain loads https")
  check(!en.navigate(tab: t1, input: "javascript:alert(1)") && !en.navigate(tab: t1, input: "file:///etc/passwd") && ff.made[t1]!.loaded.count == 1, "engine.navigate: javascript:/file: typed input refused, nothing loaded")
  check(en.navigate(tab: t1, input: "swift actors") && ff.made[t1]!.loaded.last?.host == "duckduckgo.com", "engine.navigate: words become a search")
  // page-requested link opens a new tab next to the source, selected in the window showing the source
  ff.linkOpenHandler?(t1, URL(string: "https://popup.example/x")!)
  let opened = en.state.tabs.values.first { $0.url == "https://popup.example/x" }
  check(opened != nil && opened?.space == sp && en.state.windows[wd]?.selected == opened?.id, "page link (target=_blank) opens a tab in the same space and shows it")
  // reopen last closed
  if let o = opened { en.closeTab(o.id) }
  let back = en.reopenLastClosed(); var backID: TabID? = nil; if case .restored(let i) = back { backID = i }
  check(backID != nil && en.state.tabs[backID!]?.url == "https://popup.example/x", "reopen last closed restores the tab")
  check(en.reopenLastClosed() == .notFound, "reopen with an empty archive is a no-op")
  let blankT = en.newTab(in: sp, url: "about:blank", window: wd)!; let archBefore = en.state.archive.count
  en.closeTab(blankT); check(en.state.archive.count == archBefore && en.state.tabs[blankT] == nil, "closing a never-used blank tab does not fill the archive")
  // tab state changes flow into the model + notify the UI
  var notified = 0; en.onChange = { notified += 1 }
  ff.made[t1]!.url = URL(string: "https://example.com/page2"); ff.made[t1]!.title = "Page 2"; ff.made[t1]!.onChange?()
  check(en.state.tabs[t1]?.url == "https://example.com/page2" && en.state.tabs[t1]?.title == "Page 2" && notified == 1, "tab navigation updates the saved model and notifies the UI")
}
// 24. Settings + learned habits persistence
do {
  let pp = tmpDB(); let (ses, _, _) = try SessionManager.start(path: pp)
  check(EngineSettings.loadPolicy(from: ses).defaultGrace == PolicyConfig.relaxed.defaultGrace, "settings: no saved policy -> product default")
  var mine2 = PolicyConfig.relaxed; mine2.defaultGrace = 5 * 3600; mine2.maxLive = .init(normal: 80, warning: 50, critical: 25); mine2.audibleGrace = 20 * 60
  try EngineSettings.savePolicy(mine2, to: ses)
  let back = EngineSettings.loadPolicy(from: ses)
  check(back.defaultGrace == 5 * 3600 && back.maxLive.normal == 80 && back.audibleGrace == 20 * 60, "settings: user's values persist")
  // older file without newer keys: tolerated, the rest kept
  try ses.store.setSetting("policy.v1", Data(#"{"defaultGrace": 7200, "minGrace": 1800}"#.utf8))
  let old = EngineSettings.loadPolicy(from: ses)
  check(old.defaultGrace == 7200 && old.minGrace == 1800 && old.coldGap == PolicyConfig().coldGap, "settings: an older saved file with missing keys keeps what it has, defaults the rest")
  try ses.store.setSetting("policy.v1", Data("not json at all".utf8))
  check(EngineSettings.loadPolicy(from: ses).defaultGrace == PolicyConfig.relaxed.defaultGrace, "settings: corrupt saved policy falls back to the default (no crash)")
  try ses.store.setSetting("policy.v1", Data(#"{"defaultGrace": -5, "minGrace": 1e99, "maxLive": {"normal": -1, "warning": 0, "critical": 0}}"#.utf8))
  let wild = EngineSettings.loadPolicy(from: ses); check(wild.minGrace <= wild.defaultGrace && wild.maxLive.normal >= 1 && wild.minGrace <= 24 * 3600 && wild.defaultGrace <= 7 * 86_400, "settings: absurd saved values are clamped on BOTH ends")
  var um = UsageModel(); for _ in 0..<4 { um.recordReactivation(host: "docs.example", idleSeconds: 900) }
  try EngineSettings.saveUsage(um, to: ses)
  check(EngineSettings.loadUsage(from: ses).expectedGap(host: "docs.example") == um.expectedGap(host: "docs.example"), "habits: learned gaps persist across restarts")
  try ses.store.setSetting("usage.v1", Data(#"{"entries": {"a": {"gap": 1e999, "seq": 1}, "b": {"gap": 60, "seq": 2}}}"#.utf8))
  let ru = EngineSettings.loadUsage(from: ses); check(ru.expectedGap(host: "b") == 60, "habits: a damaged entry is dropped, valid ones kept")
  try ses.store.setSetting("usage.v1", Data("garbage".utf8)); check(EngineSettings.loadUsage(from: ses).gaps.isEmpty, "habits: corrupt saved model -> empty model (no crash)")
}
// 25. Never-sleep sites
do {
  var ns = PolicyConfig.relaxed; ns.neverSleepHosts = ["chat.example", "WWW.Dashboard.Example/path?x=1", "bad host", "", "*.wild.example", "https://url.example:8443/x"]
  let v = ns.validated()
  check(v.neverSleepHosts == ["chat.example", "dashboard.example", "wild.example", "url.example"], "never-sleep: entries normalised (lowercase, no scheme/path/port/www/wildcard); junk dropped (\(v.neverSleepHosts))")
  check(v.isNeverSleep(host: "chat.example") && v.isNeverSleep(host: "app.chat.example") && !v.isNeverSleep(host: "notchat.example") && !v.isNeverSleep(host: "chat.example.evil.com"), "never-sleep: matches the domain and subdomains only (no suffix tricks)")
  check(!PolicyConfig.relaxed.isNeverSleep(host: "chat.example") && !v.isNeverSleep(host: nil), "never-sleep: empty by default; nil host safe")
  let site = tab("chat.example", idle: 90 * 86_400)
  check(hib([site], config: v).isEmpty, "never-sleep: a listed site is never hibernated, however idle")
  check(hib([tab("other.example", idle: 90 * 86_400)], config: v).count == 1, "never-sleep: other sites still sleep normally")
  let manyNS: [TabInfo] = (0..<10).map { _ in tab("chat.example", idle: 9000) }
  var bud = v; bud.maxLive = .init(normal: 3, warning: 3, critical: 3)
  check(hib(manyNS, config: bud).isEmpty, "never-sleep: exempt from the live-tab budget too (user's explicit choice)")
  let rt = try JSONDecoder().decode(PolicyConfig.self, from: JSONEncoder().encode(v)); check(rt.neverSleepHosts == v.neverSleepHosts, "never-sleep: list round-trips through JSON")
  let oldJSON = try JSONDecoder().decode(PolicyConfig.self, from: Data(#"{"defaultGrace": 3600}"#.utf8)); check(oldJSON.neverSleepHosts.isEmpty, "never-sleep: an older settings file without the key loads fine")
  // engine toggle persists
  let nsp = tmpDB(); let (nss, ns0, _) = try SessionManager.start(path: nsp, debounce: 0.05); let nse = BrowserEngine(session: nss, state: ns0, factory: FFactory())
  check(try nse.toggleNeverSleep(host: "https://Music.Example/x") == true && nse.policy.neverSleepHosts == ["music.example"], "engine: toggle adds a site")
  check(EngineSettings.loadPolicy(from: nss).neverSleepHosts == ["music.example"], "engine: the list is persisted")
  check(try nse.toggleNeverSleep(host: "music.example") == false && nse.policy.neverSleepHosts.isEmpty, "engine: toggling again removes it")
  check(try nse.toggleNeverSleep(host: "!!!") == false && nse.policy.neverSleepHosts.isEmpty, "engine: an invalid host is ignored")
}
// 26. Content-blocking settings + built-in list validity
do {
  let rulesJSON = BuiltInBlocklist.rules
  let parsed = (try? JSONSerialization.jsonObject(with: Data(rulesJSON.utf8))) as? [[String: Any]]
  check(parsed != nil && parsed!.count >= 20, "blocklist: built-in rules are valid JSON (\(parsed?.count ?? 0) rules)")
  check(parsed?.allSatisfy { ($0["action"] as? [String: Any])?["type"] as? String == "block" && (($0["trigger"] as? [String: Any])?["load-type"] as? [String]) == ["third-party"] } == true, "blocklist: every built-in rule is third-party-only (first-party requests are never touched)")
  let re = try NSRegularExpression(pattern: (parsed![0]["trigger"] as! [String: Any])["url-filter"] as! String)
  func hit(_ u: String) -> Bool { re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)) != nil }
  check(hit("https://doubleclick.net/x") && hit("http://ad.doubleclick.net/pagead") && hit("https://doubleclick.net:443/x") && !hit("https://notdoubleclick.net/x") && !hit("https://doubleclick.net.evil.com/x") && !hit("https://example.com/doubleclick.net"), "blocklist: host pattern matches the domain/subdomains only (no suffix or path tricks)")
  check(BlockingSettings().enabled == false, "blocking: off by default")
  var bs = BlockingSettings(); bs.enabled = true; bs.allowlist = ["Example.COM", "https://Site.Example/path", "bad host!", "www.shop.example"]
  check(bs.effectiveAllowlist.contains("netflix.com") && bs.effectiveAllowlist.contains("youtube.com") && bs.effectiveAllowlist.contains("primevideo.com") && bs.effectiveAllowlist.contains("googlevideo.com"), "blocking: video sites are always exempt")
  check(bs.effectiveAllowlist.contains("example.com") && bs.effectiveAllowlist.contains("site.example") && bs.effectiveAllowlist.contains("shop.example") && !bs.effectiveAllowlist.contains("bad host!"), "blocking: user allowlist is normalised, junk dropped")
  let dec = try JSONDecoder().decode(BlockingSettings.self, from: Data(#"{"enabled": true, "allowlist": ["a.example", 5, null]}"#.utf8))
  check(dec.enabled == false || dec.enabled == true, "blocking: a damaged allowlist does not throw")
  check((try? JSONDecoder().decode(BlockingSettings.self, from: Data("garbage".utf8))) == nil, "blocking: pure garbage is rejected (caller falls back to defaults)")
  let bsp = tmpDB(); let (bss, _, _) = try SessionManager.start(path: bsp)
  check(EngineSettings.loadBlocking(from: bss) == BlockingSettings(), "blocking: no saved setting -> defaults (off)")
  try EngineSettings.saveBlocking(bs, to: bss); check(EngineSettings.loadBlocking(from: bss).enabled && EngineSettings.loadBlocking(from: bss).allowlist.contains("example.com"), "blocking: settings persist")
  try bss.store.setSetting("blocking.v1", Data("garbage".utf8)); check(EngineSettings.loadBlocking(from: bss) == BlockingSettings(), "blocking: corrupt saved setting falls back to off")
}
extension PolicyConfig { init(neverSleepHosts: [String]) { self.init(); self.neverSleepHosts = neverSleepHosts } }
// 27. 6th-review fixes
do {
  // HIGH 2: one bad element must not drop the never-sleep list; partial tables keep the rest
  let j1 = try JSONDecoder().decode(PolicyConfig.self, from: Data(#"{"neverSleepHosts": ["a.example", 5, null, {"x":1}, "b.example"]}"#.utf8))
  check(j1.neverSleepHosts == ["a.example", "b.example"], "decode: a bad element in neverSleepHosts is skipped, the rest kept (\(j1.neverSleepHosts))")
  let j2 = try JSONDecoder().decode(PolicyConfig.self, from: Data(#"{"maxLive": {"normal": 80, "critical": "x"}}"#.utf8))
  check(j2.maxLive.normal == 80 && j2.maxLive.warning == PolicyConfig().maxLive.warning && j2.maxLive.critical == PolicyConfig().maxLive.critical, "decode: a partial/damaged pressure table keeps valid fields and defaults the rest")
  // HIGH 3: absurd timings cannot disable time-based sleep
  var huge = PolicyConfig.relaxed; huge.minGrace = 1e99; huge.defaultGrace = 1e99; huge.criticalFloor = 1e99
  let hv = huge.validated(); check(hv.minGrace <= 24 * 3600 && hv.defaultGrace <= 7 * 86_400 && hv.criticalFloor <= hv.minGrace, "validation: absurdly large grace values are capped")
  check(hib([tab("a.example", idle: 8 * 86_400)], config: huge).count == 1, "validation: with absurd saved values a tab idle 8 days still sleeps")
  // MEDIUM 11: usage seq reconciled, oversize trimmed
  let j3 = try JSONDecoder().decode(UsageModel.self, from: Data(#"{"seq": -5, "maxHosts": 10, "entries": {"a": {"gap": 60, "seq": 100}, "b": {"gap": 60, "seq": 101}}}"#.utf8))
  var u3 = j3; u3.recordReactivation(host: "c", idleSeconds: 60); u3.maxHosts = 10
  check(u3.gaps["c"] != nil && u3.gaps["a"] != nil && u3.gaps["b"] != nil, "usage: a stored seq <= entries cannot make new entries evictable first")
  var many = #"{"maxHosts": 10, "entries": {"#; for i in 0..<30 { many += "\"h\(i)\": {\"gap\": 60, \"seq\": \(i)}" + (i < 29 ? "," : "") }; many += "}}"
  let j4 = try JSONDecoder().decode(UsageModel.self, from: Data(many.utf8)); check(j4.gaps.count == 10 && j4.gaps["h29"] != nil && j4.gaps["h0"] == nil, "usage: an oversized saved model is trimmed to maxHosts keeping the newest")
  // LOW 12/13: normalisation
  func nh(_ s: String) -> String { PolicyConfig.normalizeHost(s) }
  check(nh("www.com") == "www.com" && nh("www.example.com") == "example.com", "host: 'www.com' is not reduced to a bare TLD")
  check(nh("https://user:pw@chat.example:8443/x") == "chat.example", "host: userinfo, port and path are dropped")
  check(nh("a.com/?u=https://evil.com") == "a.com", "host: a URL inside the query does not become the host")
  check(nh("Chat.Example.") == "chat.example" && PolicyConfig(neverSleepHosts: ["chat.example"]).isNeverSleep(host: "chat.example."), "host: trailing dot normalised, and does not bypass the list")
  check(nh("a..b") == "" && nh("") == "" && nh("é.example") == "" && nh("[::1]") == "", "host: invalid / unsupported forms are rejected, not guessed")
  // MEDIUM 4: toggle semantics for subdomains
  let tp = tmpDB(); let (ts, t0, _) = try SessionManager.start(path: tp, debounce: 0.05); let te = BrowserEngine(session: ts, state: t0, factory: FFactory())
  _ = try te.toggleNeverSleep(host: "example.com")
  check(te.neverSleepEntry(covering: "app.example.com") == "example.com", "toggle: the covering entry is reported for a subdomain tab")
  check(try te.toggleNeverSleep(host: "app.example.com") == false && te.policy.neverSleepHosts.isEmpty, "toggle: on a covered subdomain it REMOVES the covering entry (label 'Allow example.com to Sleep' is honest)")
  check(try te.toggleNeverSleep(host: "app.example.com") == true && te.policy.neverSleepHosts == ["app.example.com"], "toggle: on an uncovered host it adds exactly that host")
  check(try te.toggleNeverSleep(host: "!!!") == false && te.policy.neverSleepHosts == ["app.example.com"], "toggle: invalid host is a no-op that returns the current state")
  // list order preserved, cap
  var ordered = PolicyConfig.relaxed; ordered.neverSleepHosts = ["z.example", "a.example", "m.example", "a.example"]
  check(ordered.validated().neverSleepHosts == ["z.example", "a.example", "m.example"], "list: order kept, duplicates removed")
  var big = PolicyConfig.relaxed; big.neverSleepHosts = (0..<300).map { "h\($0).example" }
  check(big.validated().neverSleepHosts.count == 200 && big.validated().neverSleepHosts.first == "h0.example", "list: capped at 200, keeping the FIRST ones the user typed")
}
// 28. Dialog throttle
do {
  var d = DialogThrottle(); let t0 = Date(timeIntervalSince1970: 1_000_000)
  check(!d.shouldOfferSuppress(now: t0), "dialogs: the first dialogs carry no suppress option")
  for i in 0..<3 { d.recordShown(now: t0.addingTimeInterval(Double(i))) }
  check(d.shouldOfferSuppress(now: t0.addingTimeInterval(3)), "dialogs: the 4th within 10 s offers 'stop showing dialogs'")
  check(!d.shouldOfferSuppress(now: t0.addingTimeInterval(30)), "dialogs: the offer disappears once the burst is over")
  d.suppress(); check(d.suppressed, "dialogs: suppression sticks for the page"); d.reset(); check(!d.suppressed && !d.shouldOfferSuppress(now: t0.addingTimeInterval(3)), "dialogs: a new page load gets a clean slate")
}
// 29. History, bookmarks, quick search
do {
  let hp = tmpDB(); let hs = try Store(path: hp); _ = try hs.load()
  let pa = ProfileID(), pb = ProfileID(); let t0 = Date(timeIntervalSince1970: 3_000_000)
  try hs.recordVisits([(pa, "https://swift.org/docs", "Swift Docs", t0), (pa, "https://swift.org/docs", "", t0.addingTimeInterval(10)), (pa, "https://news.example/a", "News ☃ Üñí", t0.addingTimeInterval(20)), (pb, "https://other.example", "Other", t0)])
  let all = try hs.searchHistory(profile: pa, query: "")
  check(all.count == 2 && all[0].url == "https://news.example/a" && all[1].visits == 2 && all[1].title == "Swift Docs", "history: upsert counts visits, keeps the title when a later visit has none, newest first")
  let hSw = try hs.searchHistory(profile: pa, query: "swift"), hOt = try hs.searchHistory(query: "other"); check(hSw.count == 1 && hOt.count == 1, "history: substring search by title or URL")
  check(try hs.searchHistory(profile: pa, query: "ÜÑÍ").count == 1, "history: case-insensitive for unicode")
  let h1 = try hs.searchHistory(profile: pa, query: "%"), h2 = try hs.searchHistory(profile: pa, query: "_"), h3 = try hs.searchHistory(profile: pa, query: "' OR 1=1 --"); check(h1.isEmpty && h2.isEmpty && h3.isEmpty, "history: wildcard/SQL-looking input is plain text, not a pattern")
  check(try hs.searchHistory(profile: pb, query: "swift").isEmpty, "history: profiles are isolated")
  try hs.updateHistoryTitle(profile: pa, url: "https://swift.org/docs", title: "Swift Documentation"); check(try hs.searchHistory(profile: pa, query: "documentation").count == 1, "history: title updates after the visit")
  let hl1 = try hs.searchHistory(profile: pa, query: "", limit: 1), hl2 = try hs.searchHistory(profile: pa, query: "", limit: 100_000); check(hl1.count == 1 && hl2.count == 2, "history: limit is honoured and clamped")
  let b1 = try hs.addBookmark(profile: pa, url: "https://swift.org", title: "Swift"); let b2 = try hs.addBookmark(profile: pa, url: "https://swift.org", title: "dupe")
  let bmA = try hs.bookmarks(profile: pa); check(b1 == b2 && bmA.count == 1, "bookmarks: the same URL is bookmarked once")
  _ = try hs.addBookmark(profile: pa, url: "https://b.example", title: "B"); _ = try hs.addBookmark(profile: pb, url: "https://c.example", title: "C")
  let bmA2 = try hs.bookmarks(profile: pa), bmAll = try hs.bookmarks(); check(bmA2.map(\.title) == ["Swift", "B"] && bmAll.count == 3, "bookmarks: order kept, per-profile listing")
  try hs.removeBookmark(b1); check((try hs.bookmarks(profile: pa)).map(\.title) == ["B"], "bookmarks: remove")
  check(try hs.historyCount() == 3, "history: nothing is ever deleted automatically")
  // migration v3 -> v4 keeps existing data
  let mp = tmpDB(); var mh: OpaquePointer?; sqlite3_open(mp, &mh)
  sqlite3_exec(mh, """
  CREATE TABLE space(id TEXT PRIMARY KEY, name TEXT NOT NULL, profile TEXT NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE tab(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, last_active REAL NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE window(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, selected TEXT, ord INTEGER NOT NULL);
  CREATE TABLE window_last(window TEXT NOT NULL REFERENCES window(id) ON DELETE CASCADE, space TEXT NOT NULL, tab TEXT NOT NULL, PRIMARY KEY(window, space));
  CREATE TABLE setting(key TEXT PRIMARY KEY, value BLOB NOT NULL);
  CREATE TABLE archive(id TEXT PRIMARY KEY, space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, closed_at REAL NOT NULL, idx INTEGER NOT NULL, ord INTEGER NOT NULL, profile TEXT, last_active REAL);
  CREATE TABLE tab_state(tab TEXT PRIMARY KEY, state BLOB NOT NULL, updated REAL NOT NULL);
  INSERT INTO space VALUES('\(UUID().uuidString)','Keep','\(UUID().uuidString)',0);
  PRAGMA user_version=3;
  """, nil, nil, nil); sqlite3_close(mh)
  let ms = try Store(path: mp); let mstate = try ms.load()
  let mh0 = try ms.historyCount(); check(mstate.spaces.count == 1 && mstate.spaces[0].name == "Keep" && mh0 == 0, "migration v3 -> v4 keeps data and adds history/bookmarks")
  // quick search ranking
  func cand(_ k: QuickCandidate.Kind, _ t: String, _ u: String, _ r: Double = 0.5) -> QuickCandidate { QuickCandidate(kind: k, title: t, url: u, recency: r) }
  let pool = [cand(.history, "Swift Evolution", "https://forums.swift.org/evolution"), cand(.openTab, "Swift Docs", "https://swift.org/docs"), cand(.bookmark, "Swift Package Index", "https://swiftpackageindex.com"),
              cand(.closedTab, "Rust Book", "https://doc.rust-lang.org/book"), cand(.history, "Swift Docs", "https://swift.org/docs")]
  let r1 = QuickSearch.rank(pool, query: "swift")
  check(r1.first?.kind == .openTab && r1.count == 3 && r1.map(\.url).filter { $0 == "https://swift.org/docs" }.count == 1, "quick search: open tabs rank first, duplicate URLs collapse to the best source")
  check(QuickSearch.rank(pool, query: "swift docs").first?.url == "https://swift.org/docs" && QuickSearch.rank(pool, query: "swift zzz").isEmpty, "quick search: every word must match")
  check(QuickSearch.rank(pool, query: "rust book").map(\.kind) == [.closedTab] && QuickSearch.rank(pool, query: "RUST-LANG").first?.title == "Rust Book", "quick search: case-insensitive, matches the URL host too")
  check(QuickSearch.rank(pool, query: "").count == 4 && QuickSearch.rank(pool, query: "   ").count == 4, "quick search: empty query lists everything by recency")
  check(QuickSearch.rank(pool, query: "swift", limit: 1).count == 1, "quick search: limit honoured")
}
// 30. Engine: history recording, quick open, bookmarks
do {
  let ep2 = tmpDB(); let (se2, s02, _) = try SessionManager.start(path: ep2, debounce: 0.05)
  let f2 = FFactory(); let e2 = BrowserEngine(session: se2, state: s02, factory: f2)
  let sp = e2.addSpace(name: "H", profile: ProfileID()); let w = e2.openWindow(space: sp)!
  let t = e2.newTab(in: sp, url: "https://start.example", window: w)!
  let ft = f2.made[t]!
  ft.url = URL(string: "https://swift.org/docs"); ft.title = ""; ft.onChange?()
  ft.title = "Swift Docs"; ft.onChange?()
  ft.url = URL(string: "about:blank"); ft.onChange?()
  ft.url = URL(string: "https://news.example/a"); ft.title = "News"; ft.onChange?()
  let hist = se2.searchHistory(query: "")
  check(hist.map(\.url).sorted() == ["https://news.example/a", "https://swift.org/docs"], "history: one entry per finished navigation; blank pages are not history (\(hist.map(\.url)))")
  check(hist.first { $0.url == "https://swift.org/docs" }?.title == "Swift Docs", "history: the title that arrives after the visit is attached")
  ft.onChange?(); ft.onChange?(); check(se2.searchHistory(query: "news").first?.visits == 1, "history: repeated change events for the same page are ONE visit")
  // loading pages are not recorded until they finish
  let fl = f2.made[t]!; _ = fl
  // quick open ranks open tabs first and finds history/closed/bookmarks
  let t2 = e2.newTab(in: sp, url: "https://swift.org/evolution", title: "Swift Evolution")!; _ = t2
  _ = try e2.toggleBookmark(tab: t2)
  e2.closeTab(t2)
  _ = e2.newTab(in: sp, url: "https://swift.org/open", title: "Swift Open Tab")
  let qs = e2.quickSearch("swift")
  check(qs.contains { $0.kind == .openTab && $0.url == "https://swift.org/open" } && qs.contains { $0.kind == .closedTab && $0.title == "Swift Evolution" } && qs.contains { $0.kind == .history && $0.url == "https://swift.org/docs" }, "quick open: open tabs, closed tabs and history are all found")
  check(qs.first?.kind == .openTab, "quick open: an open tab ranks first")
  check(try e2.toggleBookmark(tab: t) == true && e2.isBookmarked(tab: t) && (try e2.toggleBookmark(tab: t)) == false && !e2.isBookmarked(tab: t), "bookmarks: toggle on/off for a tab")
  check(try e2.toggleBookmark(tab: e2.newTab(in: sp, url: "about:blank")!) == false, "bookmarks: a blank page cannot be bookmarked")
  // opening results
  let closedHit = qs.first { $0.kind == .closedTab }!; let beforeTabs = e2.state.tabs.count
  check(e2.openQuickResult(closedHit, in: w) == .selected && e2.state.tabs.count == beforeTabs + 1 && e2.state.windows[w]?.selected != nil, "quick open: choosing a closed tab restores and shows it")
  let hHit = QuickCandidate(kind: .history, title: "H", url: "https://history.example/x"); let n3 = e2.state.tabs.count
  check(e2.openQuickResult(hHit, in: w) == .selected && e2.state.tabs.count == n3 + 1 && e2.state.tabs.values.contains { $0.url == "https://history.example/x" }, "quick open: choosing a history entry opens it in a new tab")
  // other space's tab: choosing it switches the window's space
  let sp2 = e2.addSpace(name: "Other", profile: ProfileID()); let ot = e2.newTab(in: sp2, url: "https://elsewhere.example", title: "Elsewhere")!
  let oHit = e2.quickSearch("elsewhere").first!
  check(e2.openQuickResult(oHit, in: w) == .selected && e2.state.windows[w]?.space == sp2 && e2.state.windows[w]?.selected == ot, "quick open: choosing a tab from another space switches to that space")
}
// 31. History URL sanitising + dialog text
do {
  func hist(_ s: String) -> String? { URL(string: s).flatMap(HistoryURL.forHistory) }
  check(hist("https://example.com/a?q=1") == "https://example.com/a?q=1", "history url: normal pages are kept")
  check(hist("https://user:pass@example.com/p") == "https://example.com/p", "history url: userinfo is dropped")
  check(hist("https://app.example/cb#access_token=abc&x=1") == "https://app.example/cb" && hist("https://app.example/#/route/42") == "https://app.example/", "history url: the fragment is dropped (tokens, SPA routes)")
  check(hist("https://x.example/login?token=abc") == nil && hist("https://x.example/?code=123&state=x") == nil && hist("https://x.example/m?Magic=1") == nil && hist("https://x.example/?X-Amz-Signature=zz") == nil, "history url: URLs carrying secrets in the query are NOT recorded")
  check(hist("https://x.example/search?q=tokenizer") != nil && hist("https://x.example/?keyboard=1") != nil, "history url: harmless parameters containing those words are still recorded")
  check(hist("javascript:alert(1)") == nil && hist("file:///etc/hosts") == nil && hist("data:text/html,x") == nil && hist("about:blank") == nil && hist("ftp://x.example") == nil, "history url: only http(s)")
  check(URL(string: "https://u:p@x.example/a?token=1#f").flatMap(HistoryURL.forBookmark) == "https://x.example/a?token=1#f", "bookmark url: credentials dropped, the rest kept (explicit user choice)")
  let nasty = "line1\nline2\u{202E}evil\u{0}\u{7}\u{200B}end\tTab"
  let san = DialogText.sanitize(nasty); check(!san.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0 || $0.value == 7 || $0.value == 0x200B } && san.contains("line2") && san.contains("end"), "dialog text: bidi override / control / zero-width characters stripped")
  check(DialogText.sanitize(String(repeating: "x\n", count: 500)).split(separator: "\n").count <= 22, "dialog text: at most ~20 lines (buttons can't be pushed off-screen)")
  check(DialogText.sanitize(String(repeating: "a", count: 100_000)).count <= 1001, "dialog text: length bounded")
  check(DialogText.sanitize("héllo ☃ 日本語") == "héllo ☃ 日本語", "dialog text: normal unicode untouched")
}
// 32. 7th-review fixes: profile scoping, sanitised history, write-free search, titles, folding
do {
  let fp = tmpDB(); let (fs, f0s, _) = try SessionManager.start(path: fp, debounce: 0.05)
  let ff = FFactory(); let fe = BrowserEngine(session: fs, state: f0s, factory: ff)
  let profA = ProfileID(), profB = ProfileID()
  let spA = fe.addSpace(name: "Work", profile: profA), spB = fe.addSpace(name: "Personal", profile: profB)
  let wA = fe.openWindow(space: spA)!, wB = fe.openWindow(space: spB)!
  let tA = fe.newTab(in: spA, url: "https://work.example/dash", title: "Work Dash", window: wA)!
  let tB = fe.newTab(in: spB, url: "https://home.example/", title: "Home", window: wB)!
  _ = tB
  _ = try fe.toggleBookmark(tab: tA)                                                    // bookmark in the Work profile
  fs.recordVisit(profile: profA, url: "https://work.example/secret-report", title: "Quarterly report")
  fs.recordVisit(profile: profB, url: "https://home.example/recipes", title: "Pasta recipes")
  let inB = fe.quickSearch("work", window: wB), inA = fe.quickSearch("work", window: wA)
  check(!inB.contains { $0.kind == .bookmark || $0.kind == .history }, "palette: a Personal window never lists Work bookmarks or history (\(inB.map { "\($0.kind)" }))")
  check(inA.contains { $0.kind == .history && $0.title == "Quarterly report" } || inA.contains { $0.kind == .bookmark }, "palette: the Work window does list its own bookmarks/history")
  check(fe.quickSearch("recipes", window: wB).contains { $0.kind == .history } && !fe.quickSearch("recipes", window: wA).contains { $0.kind == .history }, "palette: history is scoped to the window's profile both ways")
  check(inB.contains { $0.kind == .openTab && $0.title == "Work Dash" }, "palette: open tabs from every space stay reachable (choosing one switches space)")
  // sanitised recording
  let ft = ff.made[tA]!
  ft.url = URL(string: "https://user:pw@news.example/a?id=1#access_token=zzz"); ft.title = "News"; ft.onChange?()
  ft.url = URL(string: "https://login.example/cb?code=SECRET123"); ft.title = "Login"; ft.onChange?()
  let rec = fs.searchHistory(profile: profA, query: "")
  check(rec.contains { $0.url == "https://news.example/a?id=1" } && !rec.contains { $0.url.contains("SECRET") || $0.url.contains("pw@") || $0.url.contains("access_token") }, "history: credentials/fragments stripped, secret-bearing URLs not recorded (\(rec.map(\.url)))")
  // bookmark title/url come from the LIVE page; credentials stripped
  ft.url = URL(string: "https://u:p@docs.example/page?x=1"); ft.title = "Docs Live"; ft.onChange?()
  let bmOK = try fe.toggleBookmark(tab: tA)   // currently bookmarked work.example/dash? stale model vs live URL differ -> toggles the LIVE page
  let bms = fs.bookmarks(profile: profA)
  check(bmOK == true && bms.contains { $0.url == "https://docs.example/page?x=1" && $0.title == "Docs Live" } && !bms.contains { $0.url.contains("u:p@") }, "bookmark: bookmarks the page being viewed (live URL/title), credentials stripped")
  // restored tabs are not new visits
  let rp = tmpDB(); let (rs, rs0, _) = try SessionManager.start(path: rp, debounce: 0.05)
  var seeded = BrowserState(); let sps = seeded.addSpace(name: "S", profile: ProfileID()); let seedTab = seeded.addTab(in: sps, url: "https://restored.example/p", title: "Restored")!
  let rf = FFactory(); _ = rs0; let re = BrowserEngine(session: rs, state: seeded, factory: rf)
  rf.made[seedTab]!.url = URL(string: "https://restored.example/p"); rf.made[seedTab]!.title = "Restored"; rf.made[seedTab]!.onChange?()
  check(rs.searchHistory(query: "restored").isEmpty, "history: a tab restored at launch is not counted as a new visit")
  _ = re
  // title race: URL changes while the title is still the previous page's
  let tp = tmpDB(); let (ts, ts0, _) = try SessionManager.start(path: tp, debounce: 0.05); let tf = FFactory(); let te = BrowserEngine(session: ts, state: ts0, factory: tf)
  let tsp = te.addSpace(name: "T", profile: ProfileID()); let tw = te.openWindow(space: tsp)!; let tt = te.newTab(in: tsp, url: "about:blank", window: tw)!
  let tft = tf.made[tt]!
  tft.url = URL(string: "https://one.example/"); tft.title = "Page One"; tft.onChange?()
  tft.url = URL(string: "https://two.example/"); tft.onChange?()                           // title still "Page One": must NOT be attached to two.example
  check(ts.searchHistory(query: "two.example").first?.title == "", "history: the previous page's title is not attached to the new URL")
  tft.title = "Page Two"; tft.onChange?()
  check(ts.searchHistory(query: "two.example").first?.title == "Page Two" && ts.searchHistory(query: "one.example").first?.title == "Page One", "history: the real title attaches once it arrives")
  // search never needs a write: buffered visits are findable, DB untouched until flush
  let bp = tmpDB(); let (bs, _, _) = try SessionManager.start(path: bp, debounce: 5)
  bs.recordVisit(profile: profA, url: "https://buffered.example/x", title: "Buffered Page")
  let n0 = try bs.store.historyCount(); let found = bs.searchHistory(profile: profA, query: "buffered")
  check(n0 == 0 && found.count == 1 && found[0].title == "Buffered Page", "search: a just-visited page is findable without a database write")
  // multi-word + folding + bounded scan
  var recs: [(profile: ProfileID, url: String, title: String, at: Date)] = []
  for i in 0..<300 { recs.append((profA, "https://google.example/p\(i)", "Google page \(i)", Date(timeIntervalSince1970: 5_000_000 + Double(i)))) }
  recs.append((profA, "https://old.example/inv", "Google invoice March", Date(timeIntervalSince1970: 1_000)))
  recs.append((profA, "https://cafe.example/menu", "Café Zürich Menü", Date(timeIntervalSince1970: 2_000)))
  try bs.store.recordVisits(recs)
  check(bs.searchHistory(profile: profA, query: "google invoice").map(\.url) == ["https://old.example/inv"], "search: ALL words are matched in SQL (an old 'google invoice' page is found among 300 newer google pages)")
  check(bs.searchHistory(profile: profA, query: "cafe zurich menu").count == 1, "search: diacritics are folded (cafe/Café, zurich/Zürich, menu/Menü)")
  let scanned = try bs.store.searchHistory(profile: profA, words: ["google"], limit: 500, scanWindow: 100)
  check(scanned.count <= 100, "search: only the most recent scan-window rows are examined (bounded cost on a huge history)")
  // ranking: diacritics + word boundaries + open tabs on one URL stay separate
  let t1 = TabID(), t2 = TabID()
  let rk = QuickSearch.rank([QuickCandidate(kind: .openTab, title: "Café", url: "https://same.example", tab: t1), QuickCandidate(kind: .openTab, title: "Café again", url: "https://same.example", tab: t2), QuickCandidate(kind: .history, title: "x-cafe-y", url: "https://h.example")], query: "cafe")
  check(rk.filter { $0.kind == .openTab }.count == 2 && rk.count == 3, "ranking: diacritic-insensitive; two open tabs on the same URL both stay reachable")
  // file modes
  func mode(_ path: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? 0 }
  let mp = tmpDB(); let (ms, _, _) = try SessionManager.start(path: mp); try ms.save(BrowserState()); _ = try ms.rotateBackup()
  check(mode(mp) & 0o077 == 0 && mode(mp + ".backup-0") & 0o077 == 0, "files: database and backup are private (0600) — created that way, not chmod'ed afterwards")
}
// 33. Window frames persist
do {
  var fs = BrowserState(); let sp = fs.addSpace(name: "W", profile: ProfileID()); let wid = fs.openWindow(space: sp)!
  fs.setWindowFrame(wid, [100, 200, 1000, 700]); check(fs.windows[wid]?.frame == [100, 200, 1000, 700], "frame: stored on the window")
  fs.setWindowFrame(wid, [Double.nan, 0, 800, 600]); fs.setWindowFrame(wid, [0, 0, 10, 10]); fs.setWindowFrame(wid, [1e9, 0, 800, 600]); fs.setWindowFrame(wid, [1, 2, 3])
  check(fs.windows[wid]?.frame == [100, 200, 1000, 700], "frame: NaN, tiny, absurd or malformed frames are ignored")
  let fp2 = tmpDB(); let fst = try Store(path: fp2); _ = try fst.load(); try fst.save(fs)
  check(try Store(path: fp2).load() == fs, "frame: survives a save/load round trip exactly")
  var nf = fs; nf.setWindowFrame(wid, nil); check(nf.windows[wid]?.frame == nil, "frame: can be cleared")
  // migration v4 -> v5 keeps windows, frame defaults to nil
  let mp4 = tmpDB(); var h4: OpaquePointer?; sqlite3_open(mp4, &h4)
  let spid = UUID().uuidString, wnid = UUID().uuidString
  sqlite3_exec(h4, """
  CREATE TABLE space(id TEXT PRIMARY KEY, name TEXT NOT NULL, profile TEXT NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE tab(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, last_active REAL NOT NULL, ord INTEGER NOT NULL);
  CREATE TABLE window(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, selected TEXT, ord INTEGER NOT NULL);
  CREATE TABLE window_last(window TEXT NOT NULL REFERENCES window(id) ON DELETE CASCADE, space TEXT NOT NULL, tab TEXT NOT NULL, PRIMARY KEY(window, space));
  CREATE TABLE setting(key TEXT PRIMARY KEY, value BLOB NOT NULL);
  CREATE TABLE archive(id TEXT PRIMARY KEY, space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, pinned INTEGER NOT NULL, closed_at REAL NOT NULL, idx INTEGER NOT NULL, ord INTEGER NOT NULL, profile TEXT, last_active REAL);
  CREATE TABLE tab_state(tab TEXT PRIMARY KEY, state BLOB NOT NULL, updated REAL NOT NULL);
  CREATE TABLE history(profile TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, visits INTEGER NOT NULL, last_visited REAL NOT NULL, url_l TEXT NOT NULL, title_l TEXT NOT NULL, PRIMARY KEY(profile, url));
  CREATE TABLE bookmark(id TEXT PRIMARY KEY, profile TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, added REAL NOT NULL, ord INTEGER NOT NULL);
  INSERT INTO space VALUES('\(spid)','Old','\(UUID().uuidString)',0); INSERT INTO window VALUES('\(wnid)','\(spid)',NULL,0);
  PRAGMA user_version=4;
  """, nil, nil, nil); sqlite3_close(h4)
  let m5 = try Store(path: mp4).load(); check(m5.windows.count == 1 && m5.windows.values.first?.frame == nil && m5.spaces.count == 1, "migration v4 -> v5 keeps windows (frame unknown = nil)")
}
// 34. Memory watchdog (per-tab ceiling)
do {
  let GB: UInt64 = 1 << 30
  check(PolicyConfig().tabMemoryCapBytes(physical: 18 * GB) == 4 * GB + GB / 2, "mem cap: automatic = a quarter of RAM (18 GB -> 4.5 GB)")
  check(PolicyConfig().tabMemoryCapBytes(physical: 4 * GB) == 2 * GB && PolicyConfig().tabMemoryCapBytes(physical: 128 * GB) == 8 * GB, "mem cap: automatic is clamped to 2...8 GB")
  var u = PolicyConfig(); u.tabMemoryCapMB = 3000; check(u.tabMemoryCapBytes(physical: 18 * GB) == 3000 << 20, "mem cap: the user's value wins")
  u.tabMemoryCapMB = 5; check(u.validated().tabMemoryCapMB == 512, "mem cap: absurdly low values are raised to 512 MB")
  u.tabMemoryCapMB = -9; check(u.validated().tabMemoryCapMB == 0, "mem cap: negative means automatic")
  u.tabMemoryCapMB = 99_999_999; check(u.validated().tabMemoryCapMB == 131_072, "mem cap: huge values are bounded")
  let dec = try JSONDecoder().decode(PolicyConfig.self, from: Data(#"{"defaultGrace":600}"#.utf8)); check(dec.tabMemoryCapMB == 0, "mem cap: an older saved config without the field decodes to automatic")
  let lm = LifecycleManager(config: { var c = PolicyConfig(); c.tabMemoryCapMB = 1000; return c }())
  let big = FakeTab(), small = FakeTab(), asleep = FakeTab(); big.mem = 1500 << 20; small.mem = 200 << 20; asleep.live = false; asleep.mem = 9999 << 20
  for t in [big, small, asleep] { lm.register(t, host: "x.test") }
  let stopped = lm.memoryWatchdog(physical: 18 * GB)
  check(stopped == [big.id] && big.shed == 1 && small.shed == 0 && asleep.shed == 0, "mem watchdog: only the live tab over the cap is stopped")
  check(lm.memoryWatchdog(physical: 18 * GB).isEmpty, "mem watchdog: a stopped tab is not stopped again")
  let typing = FakeTab(); typing.mem = 1500 << 20; typing.dirty = true; lm.register(typing, host: "z.test")
  check(lm.memoryWatchdog(physical: 18 * GB).isEmpty && typing.shed == 0, "mem watchdog: a tab with unsaved typing gets double the cap")
  typing.mem = 2100 << 20; check(lm.memoryWatchdog(physical: 18 * GB) == [typing.id], "mem watchdog: ...but not unlimited")
  u.tabMemoryCapMB = Int.max; check(u.tabMemoryCapBytes(physical: 18 * GB) == 131_072 << 20, "mem cap: an unvalidated huge value cannot overflow")
  let act = FakeTab(); act.mem = 2000 << 20; lm.register(act, host: "y.test"); lm.activate(act.id)
  check(lm.memoryWatchdog(physical: 18 * GB) == [act.id], "mem watchdog: the focused tab is protected from sleep but NOT from the memory cap")
}

// 35. extension packages (Chrome/Firefox loader + manifest normaliser)
do {
  let fm = FileManager.default
  let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("extpkg-\(UUID().uuidString)")
  func mk(_ name: String, _ manifest: String, extra: [String: String] = [:]) throws -> URL {
    let d = base.appendingPathComponent(name, isDirectory: true); try fm.createDirectory(at: d, withIntermediateDirectories: true)
    try manifest.write(to: d.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    for (k, v) in extra { try v.write(to: d.appendingPathComponent(k), atomically: true, encoding: .utf8) }
    return d
  }
  func zip(_ dir: URL, _ out: URL) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.currentDirectoryURL = dir; p.arguments = ["-q", "-r", out.path, "."]
    p.standardOutput = FileHandle.nullDevice; try p.run(); p.waitUntilExit()
  }
  let root = base.appendingPathComponent("installed", isDirectory: true)
  do {
    let ff = try mk("ff", #"{"manifest_version":2,"name":"FF","version":"1.2","browser_specific_settings":{"gecko":{"id":"ff@example.org"}},"background":{"scripts":["b.js"],"persistent":true},"permissions":["tabs","downloads","https://*.example.com/*"],"update_url":"https://x"}"#, extra: ["b.js": "1"])
    let xpi = base.appendingPathComponent("ff.xpi"); try zip(ff, xpi)
    let r = try ExtensionPackage.prepare(source: xpi, into: root)
    check(r.id == "ff@example.org" && r.isFirefox && r.manifestVersion == 2, "ext: Firefox .xpi installs under its gecko id")
    let m = try JSONSerialization.jsonObject(with: Data(contentsOf: r.directory.appendingPathComponent("manifest.json"))) as! [String: Any]
    check((m["background"] as? [String: Any])?["persistent"] as? Bool == false, "ext: MV2 persistent background becomes an event page")
    check(m["browser_specific_settings"] == nil && m["update_url"] == nil, "ext: Gecko settings and update_url are dropped")
    check(r.permissions.sorted() == ["downloads", "tabs"] && r.hostPatterns == ["https://*.example.com/*"], "ext: API permissions and host patterns are separated")
    check(r.notes.contains { $0.contains("downloads") } && fm.fileExists(atPath: r.directory.appendingPathComponent("b.js").path), "ext: unsupported APIs are reported; files are copied")
  } catch { check(false, "ext: xpi install threw \(error)") }
  do {
    let cr = try mk("cr", #"{"manifest_version":3,"name":"CR","version":"0.5","background":{"service_worker":"sw.js","scripts":["sw.js"]},"host_permissions":["<all_urls>"]}"#, extra: ["sw.js": "1"])
    let z = base.appendingPathComponent("cr.zip"); try zip(cr, z)
    let zd = try Data(contentsOf: z)
    var crx3 = Data("Cr24".utf8); crx3.append(contentsOf: [3, 0, 0, 0, 5, 0, 0, 0, 9, 9, 9, 9, 9]); crx3.append(zd)
    var crx2 = Data("Cr24".utf8); crx2.append(contentsOf: [2, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 1, 1, 2, 2, 2]); crx2.append(zd)
    check((try? ExtensionPackage.zipData(fromCRX: crx3)) == zd && (try? ExtensionPackage.zipData(fromCRX: crx2)) == zd, "ext: CRX2 and CRX3 headers are stripped exactly")
    let crxFile = base.appendingPathComponent("cr.crx"); try crx3.write(to: crxFile)
    let r = try ExtensionPackage.prepare(source: crxFile, into: root)
    check(r.id.hasPrefix("ext-") && !r.isFirefox && r.hostPatterns == ["<all_urls>"], "ext: a Chrome .crx gets a stable derived id and host access is listed")
    let again = try ExtensionPackage.prepare(source: crxFile, into: root)
    check(again.id == r.id && again.directory == r.directory, "ext: installing the same package twice is idempotent")
    let m = try JSONSerialization.jsonObject(with: Data(contentsOf: r.directory.appendingPathComponent("manifest.json"))) as! [String: Any]
    check((m["background"] as? [String: Any])?["scripts"] == nil, "ext: MV3 with both service_worker and scripts keeps only the worker")
    let folder = try ExtensionPackage.prepare(source: cr, into: root)
    check(folder.name == "CR" && folder.id.hasPrefix("ext-"), "ext: an unpacked folder installs too")
  } catch { check(false, "ext: chrome install threw \(error)") }
  do {   // review fixes: symlinks, id collisions, edited folders
    let sl = try mk("sl", #"{"manifest_version":3,"name":"SL","version":"1"}"#)
    try fm.createSymbolicLink(at: sl.appendingPathComponent("icons"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    do { _ = try ExtensionPackage.prepare(source: sl, into: root); check(false, "ext: a folder containing a symlink must be refused") } catch { check(true, "ext: a folder containing a symlink is refused") }
    let zp = Process(); zp.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zp.currentDirectoryURL = sl; zp.arguments = ["-q", "-r", "-y", base.appendingPathComponent("sl.zip").path, "."]
    zp.standardOutput = FileHandle.nullDevice; try zp.run(); zp.waitUntilExit()
    do { _ = try ExtensionPackage.prepare(source: base.appendingPathComponent("sl.zip"), into: root); check(false, "ext: a zip with a symlink entry must be refused") } catch { check(true, "ext: a zip with a symlink entry is refused") }
    let m1 = #"{"manifest_version":2,"name":"Same","version":"1","browser_specific_settings":{"gecko":{"id":"dup@x"}}}"#
    let d1 = try mk("dup1", m1, extra: ["a.js": "1"]), d2 = try mk("dup2", m1, extra: ["a.js": "2"])
    let r1 = try ExtensionPackage.prepare(source: d1, into: root), r2 = try ExtensionPackage.prepare(source: d2, into: root)
    check(r1.id == r2.id && r1.directory != r2.directory, "ext: two different packages claiming one id and version never share a folder")
    check((try? String(contentsOf: r1.directory.appendingPathComponent("a.js"), encoding: .utf8)) == "1", "ext: the first install's files are untouched by the second")
    try "3".write(to: d1.appendingPathComponent("a.js"), atomically: true, encoding: .utf8)
    let r3 = try ExtensionPackage.prepare(source: d1, into: root)
    check(r3.directory != r1.directory, "ext: editing an unpacked extension's code installs as a new copy")
    let r1b = try ExtensionPackage.prepare(source: d2, into: root)
    check(r1b.directory == r2.directory, "ext: re-installing identical content is a no-op")
  } catch { check(false, "ext: review-fix fixtures failed \(error)") }
  check((try? ExtensionPackage.zipData(fromCRX: Data("Cr24".utf8) + Data([9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))) == nil, "ext: an unknown CRX version is refused")
  check((try? ExtensionPackage.zipData(fromCRX: Data("Cr24".utf8) + Data([3, 0, 0, 0, 200, 0, 0, 0]))) == nil, "ext: a truncated CRX is refused")
  do {
    let evil = base.appendingPathComponent("evil.zip")
    let py = Process(); py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    py.arguments = ["-I", "-c", "import zipfile,sys\nz=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('manifest.json','{}'); z.writestr('../escape.txt','x'); z.close()", evil.path]
    try py.run(); py.waitUntilExit()
    do { _ = try ExtensionPackage.prepare(source: evil, into: root); check(false, "ext: a path-escaping zip entry must be refused") }
    catch let e as ExtensionPackage.PackageError { if case .unsafeEntry = e { check(true, "ext: zip-slip entry is refused") } else { check(false, "ext: wrong error \(e)") } }
    check(!fm.fileExists(atPath: base.appendingPathComponent("escape.txt").path), "ext: nothing was written outside the install folder")
  } catch { check(false, "ext: zip-slip fixture failed \(error)") }
  do { _ = try ExtensionPackage.prepare(source: base.appendingPathComponent("nope.xpi"), into: root); check(false, "ext: missing file") } catch { check(true, "ext: a missing package is an error") }
  do { let bad = try mk("bad", "{not json"); _ = try ExtensionPackage.prepare(source: bad, into: root); check(false, "ext: bad manifest accepted") } catch { check(true, "ext: a malformed manifest is an error, not a crash") }
}
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
