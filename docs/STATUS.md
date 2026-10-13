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
| Extensions (Chrome + Firefox) | implemented (host), matrix partial | install from file/.crx/.xpi/.zip/folder or store link (CRX3 signature / sha256 verified); explicit permission prompt; blocklist; per-profile; real-WebKit test of MV3 + MV2. uBO Lite blocks (CNN: 16/16 ad URLs). Not yet run: Grammarly (needs login), toolbar popups. WebKit lacks `userScripts`/`offscreen`; Apple's Passwords extension cannot run (macOS launch constraint on its helper). |
| Passkeys | **phone (QR) passkeys working** | FIDO hybrid client (QR + Bluetooth + Apple/Google tunnel) with iCloud-Keychain passkeys on the iPhone; verified against a simulated phone AND confirmed working with a real iPhone by the owner (2026-10-13). Mac-local Touch ID passkeys / system passkey sheet need Apple's entitlement (paid account + approval). |
| Apple Passwords app autofill | **blocked** | Apple's helper refuses non-approved browsers (Launch Constraint Violation); not bypassed (security rule) |
| Camera / microphone (calls) | implemented, untested with a real call | enabled only when the process has the entitlements + usage strings (ad-hoc build has them); per-site Allow prompt; test with a meeting site |
| Handoff, iCloud sync | not implemented | needs Xcode + Apple Developer account |
| Boosts, reader mode, notes, split view | not implemented | later modules |
| Draft saver (form input across crash) | not implemented | design noted |
| Private browsing | not implemented | |
| Safari baseline comparison | **blocked** | see scale |
| Signed build | partial | hardened runtime + entitlements, ad-hoc; real certificate needs the owner's Apple ID in Xcode (docs/SIGNING.md) |
| Browser identity (User-Agent) | implemented | default Safari (fixes pages served in legacy form to a bare WebKit view); choose Chrome/Firefox/Edge in Settings; docs/features/browser-identity.md |
| Light/dark for websites | implemented | follows macOS by default (live, incl. sunset switch); force light/dark in Settings; no white flash; docs/features/page-appearance.md |
| Sidebar / Arc-style UI | **first pass only; owner says it does not match Arc** | translucent sidebar, rounded page card, space tint, favicons; needs a redesign from owner screenshots (docs/HANDOFF.md, research/009, 010) |
| Tab favicons | implemented | site icon, empty square when none; stored in the app data folder |
| Boosts | not started | per-site CSS/JS per space (docs/research/010) |
| Speed pass (cache, preconnect, warm-up) | implemented | docs/results/speed-pass-20261013.md: BBC repeat visit 2.4 s -> 0.4 s, preconnect cuts first byte up to 80% |
| Page load speed vs Chrome | measured | docs/results/load-compare-20261013.md: comparable cold; modern sites are heavier than the legacy pages the old identity got |
| Adaptive frame rate (LTPO-style) | implemented | rAF governor, power-aware; measured 120 fps/15% CPU -> 45 fps/9% idle on the shader page |

Self-checks: ~400 (policy, model, store, recovery, settings, ranking, dialogs) + UI self-test + real-WebKit stress. Everything runs through `scripts/gate.sh` on every commit.
