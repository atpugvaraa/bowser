# Running the browser (plain UI, development build)

```
scripts/build-app.sh            # builds app/.build/BrowserApp/Browser.app (ad-hoc signed)
open app/.build/BrowserApp/Browser.app
```
Your data: `~/Library/Application Support/Browser/session.sqlite` (tabs, spaces, windows, archive; mode 0600) plus rolling backups next to it; web data (cookies/logins) lives in WebKit's per-profile data stores under `~/Library/WebKit/dev.kd.browser/`.

Shortcuts: ⌘K quick open (tabs, closed tabs, bookmarks, history) · ⌘D bookmark · ⌘F find · ⌘+ ⌘− ⌘0 zoom · ⌘P print · ⌘, settings · ⌘T new tab · ⌘W close tab (it sleeps into the archive) · ⇧⌘T reopen · ⌘N new window · ⇧⌘N new space · ⌘L address bar · ⌘R reload · ⌘[ ⌘] back/forward · ⌃Tab next tab · ⌘1…⌘9 tab by number · Tabs ▸ Sleep Other Tabs / Memory & Tabs…

Tests (all local, no network):
- `scripts/gate.sh` — secret scan, build (warnings = errors), ~320 self-checks, UI self-test, media capability guard. Runs on every commit.
- `scripts/ui-selftest.sh` — drives the real UI (opens windows briefly).
- `scripts/stress.sh [tabs] [cycles]` — real WebKit: hibernation, crash recovery, security rules, downloads, engine restart.
- `scripts/scale.sh` — 500-tab scale/soak (refuses to start if this Mac is under memory pressure).
- `PolicySim` — hibernation policy simulator (`swift run PolicySim 14 1`).

Known limits (see docs/LEARNINGS.md): no camera/microphone yet (needs signing + usage strings), no extensions UI yet, no passkeys yet (needs Xcode + entitlement), Netflix 4K unverified (plan), plain styling.


## Long-running measurement scripts (run when the Mac is idle)
- `sudo scripts/power-gpu.sh 60` — CPU/GPU power (mW) and GPU busy %, this browser vs Safari vs Chrome on idle / 30k-fish WebGL / three.js. Needs sudo for powermetrics.
- `scripts/soak.sh 8 500 100` — 8 h, 500 tabs, live budget 100; minute-by-minute swap / WebContent / GPU memory CSV in docs/results. `scripts/soak.sh --safari 8 500` is the Safari baseline (only browser running).
- `scripts/leaks-check.sh 480` — live `leaks` + open/close cycle memory slope. `scripts/realsites.sh 40` — real heavy sites.
