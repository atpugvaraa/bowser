# HANDOFF — read this first when restarting a chat (updated 2026-10-13)

Paste to a new Claude Code session: *"Read docs/HANDOFF.md, then docs/STATUS.md and docs/GOALS.md, and continue."*

## What this is
A personal macOS browser (this Mac only, never distributed) on the Safari engine (WKWebView): Arc-style Spaces, a very strong
engine (adaptive hibernation, memory safety), modular. Repo: `github.com/kanavdhanda/browser` (private). SwiftPM package in `app/`
(Swift 6, macOS 15.4+). Built/tested on a MacBook Pro M3 Pro 18 GB, macOS 27, Xcode 27 (license accepted by the user).

## Owner's rules (non-negotiable)
- **Never delete files anywhere** (overwrite, don't `rm`; I broke this twice by `rm -f` on my own generated reports: don't).
- No access to sensitive data elsewhere on the machine. Localhost-only servers (127.0.0.1). No AirPlay/Cast/mDNS scanning (public network). No tests that raise system permission dialogs unattended (mic/camera hung the harness once).
- **Closing a tab or window sleeps/archives it, never destroys it.**
- Priorities: 1 strong engine, 2 hibernation/archiving/resources, 3 extensions (Grammarly, Apple Passwords must work), 4 plain UI, 5 Spaces polish + Apple integration. Video (Netflix/Prime/YouTube) must keep working.
- Process: nothing is committed without `scripts/gate.sh` passing AND an independent subagent review of each big chunk (`.claude/skills/scrutinize/SKILL.md`). Commit locally; push only when asked.
- Be honest: say "not tested" rather than guess. Evidence goes in `docs/results/`.

## State: engine complete and tested; see docs/STATUS.md for the honest per-feature table
Done and measured: core model (spaces/tabs/windows/archive), SQLite store (schema v5, backup ring, corruption recovery), adaptive
hibernation (usage-learned, pressure-aware, hard protections for media/forms/downloads/calls), WebKit adapter, downloads, JS dialogs,
content blocking (native), window frame restore, **per-tab memory cap with 1 s watchdog** (hostile-page defense), Settings UI,
plain AppKit UI, 426 unit checks + real-WebKit stress + UI self-test + media-capability guard in the gate.
Measured: capabilities = Safari/Chrome (WASM SIMD/threads/4 GB, WebGL2, WebGPU, AudioWorklet, gamepad, pointer lock); JS/WASM speed = Safari;
Godot 4.7.2 web editor runs (~115 fps, 1.6 GB); 30k-fish WebGL aquarium 46 fps = Safari 45 (Chrome 81: WebKit draw-call cost, not fixable by flags);
300 tabs/60 live: 109 ms wake p50, 3.25 GB; sanitizers (ASan/TSan/UBSan) clean; `leaks`: nothing from our code (416 Apple LinkPresentation XPC); app memory flat over 480 cycles.

## NOT done / needs the owner
1. **Run the power + GPU comparison** (needs sudo): `sudo scripts/power-gpu.sh 60` -> `docs/results/power-*.md`.
2. **Run the 500-tab soak** (hours, quiet Mac): `scripts/soak.sh 8 500 100`, then the baseline `scripts/soak.sh --safari 8 500`; compare the two CSVs in `docs/results/` (swap, WebContent/GPU memory growth per hour). Not yet run at 500 tabs / hours.
3. Extensions: WKWebExtension host in `WebKitTabFactory`, popup/action UI, permission UI. Grammarly needs the owner's login. uBO Lite loads but did not block (cause unknown); native `WKContentRuleList` blocking works and is the ad-block path.
4. Signing + entitlements (Xcode is ready): camera/mic (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, then flip `MediaDevicesEnabled` in `WebKitTabFactory`), passkeys (`com.apple.developer.web-browser.public-key-credential`), Handoff/iCloud (needs a developer account).
5. Netflix 4K unverified (plan ceiling 1080p). Real casting untested (public network). MW2-in-browser reports = unofficial fan WASM port; not loaded.
6. Backlog: draft saver for form input across a crash, private browsing, clear-history UI, bookmark folders, resource panel UI, tab drag-reorder, "page unresponsive" notice (a spinning page hangs only its own tab; host survives), process-sharing nuance for the memory cap (siblings in one process are shed together).
7. Optional power idea (unmeasured): `PreferPageRenderingUpdatesNear60FPSEnabled=0` lifts light pages 60 -> ~120 fps but costs power; left at default. Measure with the power script before changing.

## Map
- `app/Sources/`: `BrowserCore` (model, URL/nav rules, error page) · `Lifecycle` (HibernationPolicy, LifecycleManager, memory watchdog) · `Persistence` (Store, SessionManager, UsageRecorder) · `Resources` (pressure, process memory) · `EngineCore` (BrowserEngine facade, settings) · `EngineWebKit` (WebKitTab, factory, downloads, feature flags) · `ContentBlocking` · `BrowserApp` (AppKit UI, SelfTest) · harnesses `CoreChecks`, `EngineStress`, `EngineScale`, `PolicySim`.
- `scripts/`: `gate.sh` (the commit gate) · `stress.sh` · `scale.sh` · **`soak.sh`** · **`power-gpu.sh`** · `leaks-check.sh` (live `leaks` + cycle test) · `realsites.sh` (real heavy sites) · `media-check.sh` · `ui-selftest.sh` · `build-app.sh` · `testserver.py`.
- `spikes/web-bench/`: `wb` harness (loads a URL, reports fps/memory/CPU, `--hostile`, `--flag Key=0/1`, `--after-load`), `aqproxy.py` (30k-fish aquarium proxy), `www/hostile/*.html` (memory/DOM/canvas/worker/popup bombs), `www/bench.html` (capability + benchmark page).
- Docs: `GOALS.md` · `PLAN.md` · `SPEC.md` · `STATUS.md` (feature table) · `LEARNINGS.md` (all findings, read the 2026-10-13 section) · `RUNNING.md` · `ENGINE_NIGHT.md` · `architecture/*.md` · `research/001-004` · `results/` (evidence).

## Build/test gotchas (hard-won)
- After `swift build`, check the exit code before `swift run --skip-build` (a failed build silently runs the old binary). `pkill -f swift-build` before retrying stacked builds.
- No `timeout` on macOS: use `perl -e 'alarm N; exec @ARGV'`. zsh does not word-split unquoted variables: use arrays.
- Avoid tuple-destructuring in `guard let`, long `&&` chains of optionals and giant async closures (type-checker blowups).
- Foreground commands time out at 10 min: use `run_in_background` + Monitor for long runs. Never `sleep` in a chain.
- Another job on this Mac (`/Users/kd/Developer/revolve/...`) sometimes eats RAM/swap; it is not ours: don't touch it. The scale/soak harness refuses to start under pressure/swap by design.
- Other browsers' tabs opened by test scripts stay open: tell the owner.

## Where we stopped (2026-10-13 ~09:10)
Last commit: per-tab memory cap + hostile/GPU/leak findings (`fd92702`), then power/soak scripts + this handoff. The autorun /loop was stopped at the owner's request.
