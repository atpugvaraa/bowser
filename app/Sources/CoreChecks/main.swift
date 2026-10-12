import BrowserCore
import Foundation
import Lifecycle

// Self-checking tests (XCTest unavailable under Command Line Tools). Exit non-zero on any failure.
nonisolated(unsafe) var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String) { if cond() { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 } }

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
  ("loading", { $0.isLoading = true }), ("userRule", { $0.userProtected = true }),
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
check(hib([tab("docs.example", idle: 25 * min)], usage: usage).isEmpty, "habitual host kept live until ~1.5x gap (floor 15 min)")
check(hib([tab("docs.example", idle: 31 * min)], usage: usage).count == 1, "habitual host released after 1.5x gap")
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
let young: [TabInfo] = (0..<10).map { i in tab("y\(i).example", idle: 60) }
check(hib(young, .critical, config: bc).isEmpty, "budget never sheds tabs idle < floor")

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

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
