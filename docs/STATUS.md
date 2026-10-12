# Feature status (honest, 2026-10-13)

Legend: **implemented** = built and covered by an automated check; **partial** = works but limited; **blocked** = needs something outside the code; **not implemented**.

| Area | Status | Notes / evidence |
|---|---|---|
| Engine: WebKit (WKWebView), one data store per profile | implemented | profile isolation + persistence verified (spikes, engine tests) |
| Tabs, windows, spaces (Arc-style model) | implemented | model fuzzed (5 seeds × 3000 ops), UI self-test through real menus |
| Closing sleeps (archive, never destroys) | implemented | tab history survives close→restore and an app restart (real WebKit) |
| Session store (SQLite, crash-safe) | implemented | SIGKILL-mid-write ×14; recovery only on real corruption; backup ring; schema v4 with migrations |
| Hibernation (adaptive, user-settable) | implemented | policy + simulator; real WebKit: 82% memory reclaimed at 24 tabs; protections for media/PiP/capture/downloads/forms/etc. |
| Resource manager | partial | per-tab memory summary dialog; memory-pressure source; no live graph |
| Never-sleep sites, settings window, learned habits | implemented | persisted, validated, tolerant decoding |
| 500-tab scale / 8 h soak vs Safari | **blocked** | this Mac is shared with another heavy job; harness refuses to run under pressure. Not measured. |
| Navigation safety (typed input, link policy, popups→tabs) | implemented | real-WebKit tests |
| Downloads (sanitised, quarantine, never auto-open) | implemented | real-WebKit test |
| Error pages (no TLS bypass) | implemented | |
| JS dialogs (throttled), file upload, fullscreen video, find, zoom, print, Web Inspector | implemented | menus + UI self-test (dialogs/upload not automated: need UI) |
| History, bookmarks, ⌘K quick open | implemented | unit + UI tests |
| Content blocking | implemented (opt-in) | native rule lists; video sites exempt; conservative list only |
| Video (Netflix 1080p, YouTube 4K HDR) | implemented | measured; Netflix 4K **unverified** (plan), Prime/F1 TV not tested |
| Extensions (Grammarly, uBO, password managers) | **not implemented** | MV3 content scripts + DNR proven in spikes; uBO Lite didn't block (unknown cause); needs host UI + logins |
| Passkeys / Apple Passwords | **blocked** | needs Xcode license (user), signing, the `web-browser.public-key-credential` entitlement |
| Camera / microphone (calls) | **blocked** | needs signing + usage descriptions (enabling without them can hang/terminate the app) |
| Handoff, iCloud sync | not implemented | needs Xcode + Apple Developer account |
| Boosts, reader mode, notes, split view | not implemented | later modules |
| Draft saver (form input across crash) | not implemented | design noted |
| Private browsing | not implemented | |
| Safari baseline comparison | **blocked** | see scale |
| Signed/notarised build | not needed (personal use) | ad-hoc signed |

Self-checks: ~400 (policy, model, store, recovery, settings, ranking, dialogs) + UI self-test + real-WebKit stress. Everything runs through `scripts/gate.sh` on every commit.
