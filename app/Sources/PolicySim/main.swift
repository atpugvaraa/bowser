import BrowserCore
import Foundation
import Lifecycle

// Replays a synthetic-but-realistic 500-tab usage trace (14 days) against hibernation policies and reports the trade-off:
// live-hit ratio (tab was already alive when you came back) vs memory (average live tabs), plus "premature" hibernations
// (tab hibernated and then needed again within 30 min). Pure logic, deterministic, no WebKit.
// usage: PolicySim [days=14] [seed=1] [out.md]
let args = CommandLine.arguments
let DAYS = args.count > 1 ? Int(args[1]) ?? 14 : 14
let SEED = args.count > 2 ? UInt64(args[2]) ?? 1 : 1
let outPath = args.count > 3 ? args[3] : nil
let N = 500, MB_PER_LIVE_TAB = 43.0, RESTORE_MS = 110.0

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
  mutating func exp(_ mean: Double) -> Double { -mean * log(max(next(), 1e-12)) } }

enum Class_ { case hot, warm, cold }
// 25 hot, 100 warm, 375 cold; hosts group tabs (10 tabs per host => habits are learnable per site)
func klass(_ i: Int) -> Class_ { i < 25 ? .hot : i < 125 ? .warm : .cold }
func hostOf(_ i: Int) -> String { "site\(i / 10).example" }

/// Access events: (minute, tab). Waking hours 8:00-24:00. Topic bursts: every few days a set of 30 tabs becomes hot for ~2 days.
func makeTrace(rng: inout RNG) -> [(Int, Int)] {
  var ev: [(Int, Int)] = []
  var rate = [Double](repeating: 0, count: N)    // accesses per waking hour
  for i in 0..<N { rate[i] = klass(i) == .hot ? 5 : klass(i) == .warm ? 0.35 : 0.012 }
  var burstUntil = [Int](repeating: -1, count: N)
  for day in 0..<DAYS {
    if day % 3 == 0 { for _ in 0..<30 { let t = 125 + Int(rng.next() * 375); burstUntil[t] = (day + 2) * 1440 } }   // new "project": 30 cold tabs get busy for 2 days
    for hour in 8..<24 {
      for i in 0..<N {
        var lam = rate[i]; if burstUntil[i] > day * 1440 { lam = 2.5 }
        var t = rng.exp(60 / max(lam, 1e-9))
        while t < 60 { ev.append((day * 1440 + hour * 60 + Int(t), i)); t += rng.exp(60 / max(lam, 1e-9)) }
      }
    }
  }
  return ev.sorted { $0.0 < $1.0 }
}

struct Result { var name: String; var hitRatio: Double; var avgLive: Double; var premature: Double; var restoresPerDay: Double; var p95LiveMB: Double }
typealias Decide = (_ live: Set<Int>, _ lastActive: [Int: Int], _ now: Int, _ active: Int, _ usage: UsageModel) -> [Int]

func run(_ name: String, trace: [(Int, Int)], decide: @escaping Decide, adaptive: Bool = false) -> Result {
  var live = Set<Int>(); var lastActive: [Int: Int] = [:]; var lastDeactivated: [Int: Int] = [:]
  var hibernatedAt: [Int: Int] = [:]
  var hits = 0, total = 0, premature = 0, restores = 0
  var usage = UsageModel(); var sumLive = 0.0, samples = 0.0; var liveSamples: [Double] = []
  var nextPolicy = 0, active = -1, lastMinute = 0
  for (t, i) in trace {
    while nextPolicy <= t {                         // policy pass every 5 simulated minutes, memory sampled each pass
      if nextPolicy > 0 { for x in decide(live, lastActive, nextPolicy, active, usage) { live.remove(x); hibernatedAt[x] = nextPolicy } }
      sumLive += Double(live.count); samples += 1; liveSamples.append(Double(live.count) * MB_PER_LIVE_TAB)
      nextPolicy += 5
    }
    if active >= 0 && active != i { lastDeactivated[active] = t }
    if adaptive, let ld = lastDeactivated[i] { usage.recordReactivation(host: hostOf(i), idleSeconds: Double(t - ld) * 60) }
    total += 1
    if live.contains(i) { hits += 1 } else {
      restores += 1; live.insert(i)
      if let h = hibernatedAt[i], t - h <= 30 { premature += 1 }
    }
    lastActive[i] = t; active = i; lastMinute = t
  }
  let days = Double(lastMinute) / 1440
  return Result(name: name, hitRatio: Double(hits) / Double(total), avgLive: sumLive / samples, premature: Double(premature) / Double(max(restores, 1)),
                restoresPerDay: Double(restores) / days, p95LiveMB: liveSamples.sorted()[Int(Double(liveSamples.count) * 0.95)])
}

var rng = RNG(s: SEED)
let trace = makeTrace(rng: &rng)
nonisolated(unsafe) var out: [String] = []
func emit(_ s: String) { print(s); out.append(s) }
emit("# Policy simulation — \(N) tabs, \(DAYS) days, seed \(SEED), \(trace.count) tab activations")
emit("Model: 25 hot / 100 warm / 375 cold tabs, waking hours 08-24, project bursts every 3 days. Live tab ≈ \(Int(MB_PER_LIVE_TAB)) MB (measured), restore ≈ \(Int(RESTORE_MS)) ms (measured). Policy pass every 5 sim-minutes.\n")
emit("| policy | live-hit % | avg live tabs | avg live MB | p95 live MB | restores/day | premature (<30 min) % |")
emit("|---|---|---|---|---|---|---|")
func row(_ r: Result) { emit("| \(r.name) | \(String(format: "%.1f", r.hitRatio * 100)) | \(String(format: "%.0f", r.avgLive)) | \(String(format: "%.0f", r.avgLive * MB_PER_LIVE_TAB)) | \(String(format: "%.0f", r.p95LiveMB)) | \(String(format: "%.0f", r.restoresPerDay)) | \(String(format: "%.0f", r.premature * 100)) |") }

// A. fixed idle timeout (Firefox/Zen-style unload, Chrome Memory Saver-style)
for tmo in [5, 15, 30, 60, 120, 240] {
  row(run("fixed idle \(tmo) min", trace: trace) { live, la, now, active, _ in live.filter { $0 != active && now - (la[$0] ?? 0) >= tmo } })
}
// B. LRU budget (keep the N most recent)
for cap in [20, 40, 60, 100] {
  row(run("LRU budget \(cap)", trace: trace) { live, la, now, active, _ in
    guard live.count > cap else { return [] }
    return live.filter { $0 != active }.sorted { (la[$0] ?? 0) < (la[$1] ?? 0) }.prefix(live.count - cap).map { $0 }
  })
}
// C. ours: adaptive grace (learned per-host return time) + budget, default user settings
func oursCfg(_ mut: @escaping (inout PolicyConfig) -> Void) -> Decide {
  { live, la, now, active, usage in
    var cfg = PolicyConfig(); cfg.budgetFloor = .init(normal: 300, warning: 120, critical: 30); mut(&cfg)
    let base = Date(timeIntervalSinceReferenceDate: 0)
    let tabs: [TabInfo] = live.map { i in var t = TabInfo(id: TabID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!), host: hostOf(i), lastActive: base.addingTimeInterval(Double(la[i] ?? 0) * 60)); t.isActive = i == active; return t }
    let d = HibernationPolicy.evaluate(tabs: tabs, pressure: .normal, usage: usage, now: base.addingTimeInterval(Double(now) * 60), config: cfg)
    let ids = Set(d.hibernate); return live.filter { i in ids.contains(TabID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!)) }
  }
}
// (name, minGrace min, defaultGrace min, coldGap min, gapFactor, budget)
let variants: [(String, Double, Double, Double, Double, Int)] = [
  ("default (min15 def60 cold45 k3 b100)", 15, 60, 45, 3, 100),
  ("min30 def60 cold45 k3 b100", 30, 60, 45, 3, 100),
  ("min30 def60 cold90 k3 b100", 30, 60, 90, 3, 100),
  ("min45 def90 cold90 k3 b100", 45, 90, 90, 3, 100),
  ("min60 def90 cold120 k4 b100", 60, 90, 120, 4, 100),
  ("min20 def60 cold120 k3 b100", 20, 60, 120, 3, 100),
  ("min30 def120 cold120 k4 b100", 30, 120, 120, 4, 100),
  ("min60 def120 cold240 k4 b100", 60, 120, 240, 4, 100),
  ("min30 def60 cold90 k3 b60", 30, 60, 90, 3, 60),
  ("min45 def90 cold90 k3 b60", 45, 90, 90, 3, 60),
]
row(run("**adaptive RELAXED preset** (product default)", trace: trace, decide: oursCfg { c in c = PolicyConfig.relaxed; c.budgetFloor = .init(normal: 300, warning: 120, critical: 30) }, adaptive: true))
for v in variants {
  row(run("**adaptive** " + v.0, trace: trace, decide: oursCfg { c in
    c.minGrace = v.1 * 60; c.defaultGrace = max(v.2 * 60, v.1 * 60); c.coldGap = v.3 * 60; c.gapFactor = v.4
    c.criticalFloor = min(5 * 60, c.minGrace); c.maxLive = .init(normal: v.5, warning: v.5, critical: v.5); c.maxGrace = 6 * 3600 }, adaptive: true))
}
if let p = outPath { try? out.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8) }
