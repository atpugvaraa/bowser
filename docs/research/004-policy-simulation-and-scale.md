# 004 — Hibernation policy: simulation, scale runs, and what they taught (2026-10-13)

## Setup
- `PolicySim` (app/Sources/PolicySim): replays a synthetic 500-tab / 14-day usage trace (25 hot, 100 warm, 375 cold tabs; waking hours; 3-day "project" bursts) through policies. Constants measured on this Mac: ~43-49 MB WebContent per live tab, ~110 ms restore (p50), 0.3-0.7 ms policy evaluation at 500 tabs.
- `EngineScale` (app/Sources/EngineScale, scripts/scale.sh): real WebKit, 500 mixed pages (light/article/SPA/heavy/canvas-animation/chatty/audio), heavy-tailed activations, memory guard.
- Raw tables: docs/results/policy-sim-14d-seed{1,2,3}.md, engine-scale-*.md.

## Finding 1 — my first "adaptive" rule was WORSE than a fixed timeout (and I would not have noticed without the simulator)
The first design capped a habitual tab's grace at 1.5x its usual return gap, so the tabs the user returns to MOST got the SHORTEST grace. At equal memory it lost to both baselines (70.5% live-hit @ ~46 tabs vs 83.1% @ 53 for a plain 60-min timeout; premature hibernation 49% vs 20%).
**Fix (break-even rule):** a tab whose usual gap <= coldGap (45-90 min) is kept ~3x that gap (bounded); a habitually cold tab is released early (minGrace); unknown hosts get the default; over budget the tab most overdue *relative to its own habit* goes first.

## Finding 2 — honest size of the win
Across 3 seeds the product preset (`PolicyConfig.relaxed`: min 45 min, default 90 min, cold 90 min, k=3, budget 100/70/40) gets ~81.7% live-hit at ~2.08 GB average (peak 3.6 GB). A fixed timeout interpolated to the same memory gets ~80.7%; a fixed 60-min timeout gets 83.3% at 2.24 GB (peak 3.9 GB); LRU budget 60 gets 75.5% at 2.5 GB. So: **clearly better than LRU budgets, ~+1 point and ~7% lower peak than a tuned fixed timeout.** Not a breakthrough, because the synthetic trace has memoryless returns, so habits carry little signal. Real traces may differ in either direction => `UsageRecorder` (opt-in, hashed, local) exists so the policy can be tuned on real behaviour.
**Caveats:** synthetic trace; constant 43 MB/tab; "hit" = tab already live. Do not quote these numbers as browser-vs-browser results.

### Update after the third independent review (numbers re-measured)
The review found real flaws; fixing them moved the numbers, which is why the sim is the objective:
- Eviction order was incoherent (overdue-ratio could shed a hot tab before a cold one). Now: shed the tab whose OWN grace expires soonest.
- A cliff at `coldGap` (45 min habit -> 135 min grace, 46 min -> 15 min). A wide linear taper fixed continuity but cost +340 MB for +1 hit point; a **narrow taper (25% of coldGap)** keeps continuity at ~no memory cost.
- Recording "not returned yet" (censored) at the moment of hibernation was noise, not signal (most tabs return soon after): removed from the sim; `UsageModel.recordNoReturn` stays for tabs that were closed/archived without returning.
- Final (3 seeds, v5): relaxed preset **~82.0% live-hit @ ~2.14 GB avg, peak ~3.7 GB**; fixed 60-min: 83.3% @ 2.24 GB, peak 3.9 GB; interpolating a fixed timeout to 2.14 GB gives ~81.2%. **Net: ~+0.8 points and ~4% lower peak vs a tuned fixed timeout; ~+10 points vs an LRU budget at equal memory.** The preset was chosen on seed 1 and confirmed on seeds 2-3 of the SAME generator (not independent traces): treat as a sanity check, not validation.

## Finding 3 — what actually matters for UX
A restore costs ~110 ms (p50), 122 ms p95, 165 ms p99 (real WebKit, 500-tab run), so a *miss* is nearly invisible. What users feel is **lost state**: JS state, form input, video position, live sessions. Hence: hard protections (audio/PiP/capture/call/download/upload/dirty form incl. iframes/loading/DevTools), recently-audible grace, and a soft longer grace for tabs with live WebSocket/EventSource. History + scroll survive via `interactionState` (verified); cookies/logins untouched (shared data store).

## Finding 4 — this Mac is the constraint, not the engine
- Measured ~39-49 MB WebContent per live tab; 500 tabs all live would be ~19-24 GB on an 18 GB Mac (estimate, not run).
- Real 500-tab runs were stopped by the memory guard: at 480 tabs (pressure warning) and in the soak (swap +3.9 GB in 30 s while my live set was shrinking). The machine was ALSO running another heavy Python workload (swap 7.4/8 GB) — not mine; I did not touch it and paused heavy runs. Scale/soak numbers must be re-taken on a quiet machine.
- 500-tab build: 25 s, 75 live / 425 hibernated, 3.7 GB WebContent; store save 3 ms / load 1 ms / 532 KB; tab-state blobs 354 KB; policy 0.6 ms; live-hit 49% (pressure had cut the budget to 55-75); resume p50 111 / p95 122 / p99 165 ms; 0 audio-tab hibernations; no host-memory growth (127-148 MB).

## Bugs the harnesses found in my own code (all fixed)
dirty-form script never installed; restore verified URL only (not history); crash test looked for pid too early; stale binary after failed build (twice); churn ignored protections; budget floor refused to shed recent tabs at ANY pressure; signals() could hang forever; iframe input missed; NUL bytes truncated in SQLite; crash test could pass vacuously; test server matched `/sse.html` as the stream.
