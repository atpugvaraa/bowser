# Engine night plan (autorun, 2026-10-12 → morning)

Goal: the strongest, most efficient core engine — tested by trying to break it. Rules from the user: nothing deleted from the machine, no access to sensitive data outside this project, scrutinizer gates every commit, video/Netflix must keep working.

## Principles (from the user)
- **Closing never destroys.** Closing a tab or window *sleeps/archives* it (recoverable, undoable); only an explicit "purge" removes data.
- **Adaptive, not annoying.** Never sign the user out, never drop media/forms/downloads, learn habits, user-settable limits.
- **Modular.** Everything behind small protocols; first-party features are modules.

## Workstreams
1. **Model: sleep-on-close.** `closeTab` archives (URL/title/space/index/closedAt) instead of dropping; `restore`, bulk restore, `purge` explicit; windows close without touching tabs. Persist (schema v2 + migration test).
2. **EngineWebKit adapter.** `WebKitTab`: lazy WKWebView, `hibernate()` (capture `interactionState`, URL, scroll; destroy the web view), `resume()`; media/capture/loading/download/dirty-form signals feeding `TabInfo`; crash recovery (`webViewWebContentProcessDidTerminate`); per-tab memory via WebContent pid footprint.
3. **Stress & break harness (`EngineStress`)**: N tabs of synthetic heavy pages; hibernate/resume cycles ×hundreds; kill -9 WebContent mid-load; leak check (weak refs must die); memory reclaimed per hibernation; rapid tab churn; policy+engine integration under simulated pressure. Results → `docs/results/`.
4. **Fault injection**: store corruption, disk full simulation, concurrent saves, clock jumps/sleep-wake, duplicate ids, malformed URLs, huge titles, 10k tabs.
5. **Extension strategy (user: "replace what the engine already has")**. Findings: WKWebExtension works for MV3 basics (spike) but uBO Lite didn't block and many APIs are absent. Plan: (a) native **content blocking** with `WKContentRuleList` (Safari-grade, no extension runtime needed) as the ad-blocking path; (b) first-party **Module API** (Swift) for features we own; (c) keep WKWebExtension only for third-party compatibility (Grammarly, password managers) behind the `Extensions` module so it can be swapped.
6. **Perf**: measure tab-switch latency, restore latency, memory/idle-tab; compare to Safari (baseline) where possible without network.

## Status log
(append as work lands; see LEARNINGS.md for findings)

### Log
- 18:2x–18:4x (night 1): EngineWebKit adapter + EngineStress harness landed. 24 tabs: 1190 → 213 MB (82% reclaimed), 24/24 restored, 200 cycles no leak, WebContent SIGKILL recovered. Real SIGKILL-mid-write crash test for the store (14/14). Fuzz found NUL-truncation bug (fixed). Closing = archive (schema v2). See research/003.
- Decided: do NOT patch/strip system WebKit (SIP, FairPlay, updates). Feature flags worth ~5% only.
- Queued next: policy additions (recently-audible grace, DevTools-open protection, per-site never-hibernate rules), draft-saver for form input, WKContentRuleList blocking, memory-pressure source (DispatchSource.makeMemoryPressureSource) wired to PressureLevel, per-tab memory accounting wired into policy, window/space UI shell, long soak (hours) with periodic sampling.

- (night 1, later) Landed + tested: LifecycleManager (race-safe orchestration), SessionManager (backup ring, quarantine, debounce), BrowserEngine facade (reconcile-based, lazy launch, closing sleeps), WebKitTabFactory (one persistent data store per profile). Real-WebKit proof: history survives close->restore AND a full app restart from SQLite; frozen WebContent (SIGSTOP) doesn't hang the pass; protected tabs never hibernated; live-connection signal; hostile-message hardening.
- 247 self-checks + 5-seed fuzz + 14x SIGKILL crash test + real-WebKit stress (all in the gate except the WebKit stress/scale harnesses, which are run via scripts/stress.sh, scripts/scale.sh).
- Blocked: 500-tab scale/soak re-run needs a quiet machine (another heavy job holds ~8 GB swap). Harness refuses to start under pressure (by design).
- Next: content blocking module (WKContentRuleList, proven working), window/space UI shell, draft saver, per-site rules, long soak on a quiet Mac, Safari baseline.
