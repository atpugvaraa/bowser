# Waterfall plan (rev 3) — personal macOS browser, this machine only

Sources of truth: `../BROWSER_MASTER_PROMPT.md` (requirements), `GOALS.md`, `LEARNINGS.md`. Each phase: scope -> checks -> tests -> exit gate. Next phase starts only when the gate passes and `scrutinize` is PASS. Status labels: implemented / partial / blocked / not implemented (master prompt §3.9). No metric without a recorded measurement (§21).
Time: Core 40%, Hibernation/archive/resources 25%, Extensions 15%, rest 20%.
Scope relaxations (personal use): no notarization/distribution/auto-update, ad-hoc signing, no multi-user hardening. NOT relaxed: TLS, permissions, isolation, credential handling, data integrity.

## Phase 0 — Research & decision (bounded, ~1 week)
Scope: Safari-as-baseline measurements (§21); video/DRM matrix (Netflix, Prime, YouTube; Netflix 4K); Safari entitlement/privilege analysis (REA+Ghidra, read-only, §1.3); extension spike (tab/window registration, uBO/uBO Lite, Grammarly, Bitwarden); per-Space data-store isolation test; Orion + GitHub survey (license-checked); Zen's Apple-Passwords approach (Gecko/MPL, different engine — learn, don't port).
Checks: every finding in `docs/research/NNN-*.md` (question, method, evidence, confidence, unknowns, implications).
Tests: spike apps in `spikes/`, results reproducible by script.
Gate: `docs/architecture/engine-decision.md` written with evidence; WebKit-vs-Chromium decided (reassess Chromium only if video/extension needs are hard blockers, §2).

## Phase 1 — Requirements & spec
Scope: must/should/later list from master prompt; perf budgets from Phase 0 baselines; data model; threat model; module boundaries (core, lifecycle, store, extensions, later modules: reader/notes/save).
Gate: you sign off. 

## Phase 2 — Architecture
Scope: engine behind interface (§2); tab/window/profile model implementing `WKWebExtensionTab/Window` from day one; SQLite schema + migrations (§18); hibernation state machine (§7); observability (logs/metrics).
Gate: design doc reviewed; risks logged.

## Phase 3 — Core browser (largest)
Scope: app shell (.app via SwiftPM or Xcode project), tabs create/close/reorder/switch, address+search, back/forward/reload/progress, downloads (safe handling), find, history, bookmarks, permissions prompts, TLS error UI, popups/window.open, fullscreen/PiP, media keys, audio indicators, context menus, keyboard shortcuts, session restore, crash recovery (web content process termination), profile persistence, secure credential flow via system AutoFill (§13).
Checks: scrutinize checklist every change; memory ownership audit of WKWebView/delegates; navigation policy allowlist.
Tests: unit (tab model, store, URL normalization), UI smoke (XCUITest after Xcode), crash tests (kill -9 app and WebContent), data-integrity tests, manual video matrix.
Gate: daily-drivable for video + research; no data loss on kill -9; tests green.

## Phase 4 — Hibernation, archiving, resource manager
Scope: real hibernation (destroy/recreate WKWebView, preserve URL/history/scroll/form state, §7); protected tabs (audio, video, downloads, forms, calls); pressure-aware policy; Arc-style auto-archive separate from hibernation (§8); resource manager with measured vs estimated vs unavailable (§9); bounded caches; battery-aware.
Tests: policy unit tests; restore-latency benchmark; memory-reclaimed measurement; soak harness (§21 workloads 1–7).
Gate: 8 h soak, 100–300 tabs, compared to Safari first (then Zen/Arc) on memory, GPU, CPU, battery, restore latency; no sustained growth/leaks; result in `docs/results/`.

## Phase 5 — Extensions
Scope: WKWebExtension host (§15), popup/action UI, permission review, install from folder/zip/CRX/XPI, compatibility matrix. Must-have targets: Grammarly, an Apple-Passwords path (system AutoFill; extension if feasible), uBlock Origin (Lite or full). 
Gate: matrix documented; targets pass or documented blocked with alternative.
**Milestone: plain-UI working browser.**

## Phase 6 — Organization UX (§4–6, 20): Spaces, per-Space profiles, sidebar, folders, favorites, split view, command palette.
## Phase 7 — Apple integration (§10–13): Handoff, iCloud sync (optional), passkeys; needs Xcode + dev account.
## Phase 8 — Dev tools, Boosts, slow-network, polish (§14, 16, 17).
## Phase 9 — Hardening (§19, 21): leak/regression suite, security review, accessibility.
## Later modules (separate SwiftPM targets): reader mode, page saving, notes.

## Cross-cutting checks (every phase)
scrutinize skill + `scripts/gate.sh`; docs updated (README, architecture, research, testing, known limitations); LEARNINGS.md appended; no copied proprietary code/assets; REA/Ghidra output = understanding, independent implementation.

## Platform target (decided 2026-10-12)
- **Minimum macOS 15.4** (native `WKWebExtension`). Set `platforms: [.macOS("15.4")]`.
- macOS 14 / <15.4: best-effort only, guarded by `#available`; no custom extension host unless asked later.
- Baselines (Safari etc.) are taken on the OS actually in use; re-measure after any OS change.

## Known constraints
- Safari holds Apple-only entitlements (fairplay-client, any-rpid auth, credential identities, safari-extension host); third-party apps cannot obtain them. Netflix 4K and Apple Passwords parity are NOT promised; tested and reported.
- Master prompt forbids private APIs (§9, 10, 19). Decision pending whether to relax for this personal build.
