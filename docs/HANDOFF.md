# HANDOFF — read this first when restarting a chat (updated 2026-10-13, ~15:30)

**Command to continue (paste into a new Claude Code session, or any coding agent run in /Users/kd/Developer/browser):**

> Read docs/HANDOFF.md, then docs/STATUS.md and docs/GOALS.md, and continue with the NEXT TASKS section.

## What this is
A personal macOS browser (this Mac only, never distributed) on the Safari engine (WKWebView). Arc-style Spaces, a very strong engine (adaptive hibernation, memory safety), extensions, phone-QR passkeys, modular. Repo: `github.com/kanavdhanda/browser` (private; **local commits are ahead of the pushed `a750ac3`; push only when the owner asks**). SwiftPM package in `app/` (Swift 6, macOS 15.4+). MacBook Pro M3 Pro 18 GB, macOS 27.0.1, Xcode 27. Last commit when this was written: `88bf8ec`.
Run the current build: `scripts/build-app.sh --release` creates `dist/Browser-<time>.app` (the build id is in About). Owner's own copy to open: the newest `dist/Browser-*.app`.

## Owner's rules (non-negotiable)
- **Never weaken macOS security** (no SIP/AMFI/boot-args/Gatekeeper/TCC tricks, no research into them; the permission classifier also blocks it). Find another way.
- **No deleting files.** One exception was granted on 2026-10-13: deleting OLD BROWSER BUILDS in `dist/` (done). Anything else needs a fresh explicit request. Overwrite, never `rm`. (Also: overwriting a binary macOS already ran gets it SIGKILLed; each release build goes to a fresh `dist/Browser-<time>.app`.)
- No access to sensitive data elsewhere on the machine (never read other apps' or Chrome's user data; throwaway profiles only). Localhost-only servers. No AirPlay/Cast/mDNS scanning (public network). Bluetooth scanning only while the passkey sheet is open. No tests that raise permission dialogs unattended.
- **Closing a tab/window sleeps/archives it, never destroys it.**
- Priorities: engine first; hibernation/archive/resources; extensions; **now: core UI (sidebar, profile spaces, Boosts) with low animation, must not slow page loading**; split view later.
- Process: nothing committed without `scripts/gate.sh` passing (it is the pre-commit hook: secret scan, strict `swift build`, ~500 CoreChecks, UI self-test, media guard) AND an independent subagent review of each big chunk (`.claude/skills/scrutinize/SKILL.md`). No attribution lines in commit messages. Be honest: "not tested" beats a guess; evidence goes in `docs/results/`.
- Ask the owner before big direction changes; they said "we do not move ahead without planning" for large steps.

## State (see docs/STATUS.md for the per-feature table)
Done and verified: engine, store, hibernation, memory watchdog, content blocking, downloads, Settings; **clean power test (this browser == Safari)**; **adaptive frame governor** (power-aware, idle tiers); **extension engine** (Chrome + Firefox: folder/.crx/.xpi/.zip + store links with CRX3 signature / sha256 checks, explicit permission prompt, blocklist, per-profile; uBO Lite blocks on real sites); **phone-QR passkeys (FIDO hybrid client; owner confirmed it works with a real iPhone)**; **Safari identity by default + selectable Chrome/Firefox/Edge**; **light/dark for websites follows macOS (live) + force option**; **speed pass** (speculative cache revalidation, preconnect while typing; docs/results/speed-pass-20261013.md; loads comparable to Chrome, docs/results/load-compare-20261013.md and cache-warm-compare-20261013.md); camera/mic gated on entitlements; signing-ready build (docs/SIGNING.md); favicons in the tab list (empty square when a site has none); first-pass sidebar UI.

## **UI status: the first-pass sidebar is NOT good enough (owner: "very very bad, not matching Arc") — top priority**
What exists (`app/Sources/BrowserApp/BrowserWindowController.swift` `buildUI`, `SidebarViews.swift`, `FaviconStore.swift`): translucent sidebar with traffic lights, nav buttons + address field in the sidebar, space popup ("Main"), tab list (favicon chip + title, close on hover/selection), "New Tab" button, page shown as a rounded card inside a space-tinted frame (corners are PAINTED over the web view by `CardFrameOverlay`, never masked: masking a web view forces offscreen compositing and costs frame rate), light/dark tint from the space id (`SpacePalette`).
Why it falls short (owner's verdict; specifics to confirm with them): does not look or behave like Arc. Missing: pinned/favorites area, space switcher chips with colours/icons at the bottom, per-space colour picker, space/profile indicator, compact density and spacing like Arc, hover states, drag to reorder, folders, command bar styling, proper top-of-sidebar layout. Ask the owner for screenshots / a short recording of their Arc setup and the 5 behaviours they use daily BEFORE redesigning.
Design aids built in: `SELFTEST_SHOTS=<dir> scripts/ui-selftest.sh` writes `ui-light.png` / `ui-dark.png` of the real window (read them with an image viewer to review the design; web content is blank in the snapshot). `SELFTEST_FPS=<url> scripts/ui-selftest.sh` prints the page fps inside the real window (one run returned 0.08 fps, probably the window was occluded by other windows; re-run before trusting; the governor drops idle pages to half/quarter rate by design). Page-load A/B: `app/.build/out/Products/Debug/ExtLab bench-local <url> <n> [--plain]` and `bench <url>` (see scripts/chrome-load-bench.py for Chrome).
Guardrails for UI work: no layer masking on web views, no per-frame work, simple low animation; after each UI step re-run the local load benchmark (`ExtLab bench-local http://127.0.0.1:<port>/lb.html 15`, product vs `--plain`, was 13 ms vs 16 ms) and the gate. Keep `addressField`, `extButton`, `rows`, menus and engine behaviour intact (the UI self-test drives them).

## About Arc, Ghidra and reverse engineering (owner asked for this to be recorded)
- The owner asked to copy Arc's exact features "using Ghidra and REA" and asked for instructions to continue that with another tool.
- **Verified 2026-10-13:** Arc's Terms of Use (https://start.arc.net/terms-of-use) prohibit anyone who "decompiles, reverse engineers, or otherwise attempts to obtain the source code or underlying ideas" of the software, and prohibit derivative works. The assistant therefore did NOT analyse Arc's binary and did not write an Arc-specific Ghidra recipe. The project plan's own rule also applies: "REA/Ghidra output = understanding, independent implementation; no copied proprietary code/assets" (docs/PLAN.md, cross-cutting checks).
- Whether to analyse Arc on their own is the owner's decision and responsibility, outside this repo's rules. General Ghidra documentation: https://ghidra-sre.org . Nothing from such analysis may be pasted into this project as code or assets.
- **Legitimate ways to get the same information (use these):** (1) the owner's screenshots / screen recordings of Arc, measured frame by frame (spacing, radii, colours, hover states, animation timing); (2) the macOS Accessibility Inspector on the owner's own screen to see Arc's control layout (observation of the UI, not of the code); (3) Arc's public help pages, release notes and videos; (4) open-source Arc-like browsers, read as references (docs/research/010-open-source-references.md): **Nook** (GPL-3.0, WebKit/SwiftUI, managers for split view/peek/extensions/tweaks), **Ora** (GPL-3.0, WebKit/AppKit/SwiftUI, Sidebar/Tabs/Launcher folders, Vendor/SplitView), **Aura**, **Zen Browser** (MPL-2.0, Firefox base; best-documented behaviours: workspaces, split view, Glance, compact mode, Mods). GPL code may be read freely; do not copy it (the combined work would become GPL if ever distributed); implement independently.

## NEXT TASKS (in order)
1. **Redesign the sidebar/UI to match Arc's look and behaviour** (see "UI status"). Slice order:
   - **(a) Profiles & Spaces architecture (COMPLETED 2026-10-13):** Schema v6 migration, first-class `ProfileRecord`, multiple spaces per profile sharing logins/cookies, space custom icons & hues (`SpacePalette`), Edit Space sheet, profile switcher with session reloading.
   - **(b) Sidebar visual wireframe & hierarchy (COMPLETED 2026-10-13):** Exact match of the user's reference screenshots (`uploaded_media_1791890022540.png`, `uploaded_media_1791885772086.png`):
     - Top nav: Traffic lights (70pt left offset), `sidebar.left` toggle button, `←` back, `→` forward, `↻` reload.
     - Address field: Full-width rounded field in sidebar with tail truncation and domain display.
     - Favorites container: 1pt dashed border rounded card, `star.circle`, "Drag to add Favorites", and dismiss `✕`.
     - Space header: `[Emoji] [Space] · [Profile]` with popup switcher.
     - Pinned section: Collapsible folders (`📁 Pull Requests`, `📁 Capstone`) with disclosure chevrons and indented tabs (`Review PR #42`), plus standalone pinned tabs.
     - 0.5pt subtle horizontal divider.
     - `+ New Tab` action button directly beneath the divider and above unpinned tabs.
     - Unpinned ephemeral tab list with active pill card highlight (`#38383c`).
     - Bottom Spaces Dock: extensions `🧩` button on far left, space indicator pills in center, and `+` add space button on far right.
   - **(c) Command Bar / New Tab modal (COMPLETED 2026-10-13):** Centered floating card (`#1e1e21`, 14pt radius, drop shadow), search field `Search or Enter URL...` with magnifying glass and info button, real-time open tab matching across spaces with `Switch to Tab ➔` pills, and keyboard/agentic navigation.
   - **(d) Gestures & Animations (COMPLETED 2026-10-13):** `⌘S` smooth sidebar collapse/expand into the left edge, two-finger horizontal trackpad swipe to switch spaces with haptic feedback, 0.15s Command Bar spring presentation.
   - **(e) Polish & Boosts (NEXT):** Per-space custom color swatch picker in Edit Space sheet, tab loading animations, Boosts (per-site user CSS/JS stored per space).
2. Speed pass follow-ups (owner approved): measure battery/memory effect of preconnect; consider prefetch only if measured and opt-in.
3. Extensions: run Dark Reader, Vimium, Bitwarden through `ExtLab` (`ExtLab chrome:<id>|firefox:<slug>|<dir> <url> <secs> --eval <js>`); Grammarly needs the owner's login; toolbar popups untried; `userScripts`/`offscreen` shims not built; per-space extension enablement.
4. Passkeys follow-ups: conditional-UI (autofill) passkeys, iframe passkeys, account chooser; Touch ID local passkeys only if the owner asks.
5. Certificate: the owner adds their Apple ID in Xcode (docs/SIGNING.md); then `scripts/build-app.sh` signs automatically. Mac-local passkeys / Apple Passwords stay blocked (needs Apple's entitlement; Apple's Passwords helper refuses non-approved browsers).
6. Backlog: private browsing, clear-history UI, bookmark folders, resource panel UI, draft saver for forms across a crash, "page unresponsive" notice, Netflix 4K verify, auto-archive tabs by age (verify), accessibility pass (VoiceOver/keyboard), frame-governor power measurement (`sudo scripts/power-gpu.sh 60`), later modules (reader mode, page saving, notes).

## Map
- `app/Sources/`: `BrowserCore` (model, URL rules) · `Lifecycle` (hibernation, watchdog) · `Persistence` (SQLite store) · `Resources` · `EngineCore` (BrowserEngine facade) · `EngineWebKit` (WebKitTab, factory, ExtensionHost, PasskeyBridge, FrameGovernor, BrowserIdentity, PageAppearance, SpeedTuning) · `Extensions` (package loader, store downloader, CRX3 verifier) · `Hybrid` (CBOR, hybrid protocol, Noise, BLE, WebAuthn, simulator) · `ContentBlocking` · `BrowserApp` (UI: window controller, SidebarViews, FaviconStore, ExtensionsUI, PasskeyUI, Settings, SelfTest) · harnesses `CoreChecks`, `EngineStress`, `EngineScale`, `PolicySim`, `ExtLab`.
- `scripts/`: `gate.sh` · `stress.sh` (real-WebKit stress incl. extensions, passkeys, identity, appearance, speed) · `ui-selftest.sh` · `build-app.sh [--release]` · `soak.sh` · `power-gpu.sh` · `chrome-load-bench.py` · `fg-js.sh` · `signing/` (entitlements) · `testserver.py`.
- Docs: `GOALS.md`, `PLAN.md`, `STATUS.md`, `LEARNINGS.md` (read the 2026-10-13 sections), `SIGNING.md`, `features/*` (browser-identity, page-appearance), `research/005-010`, `results/*` (evidence).

## Build/test gotchas (hard-won)
- Check the exit code of `swift build` before `swift run --skip-build`. Kill stacked builds with `pkill -f swift-build`.
- No `timeout` on macOS: `perl -e 'alarm N; exec @ARGV'`. zsh does not word-split unquoted variables.
- Avoid tuple destructuring in `guard let`, long optional `&&` chains and giant async closures (type-checker blowups). Heredoc escaping: in a quoted heredoc `\(` stays literal, so write Swift `\(` not `\\(`.
- Foreground commands time out at 10 min: use background runs. Never chain `sleep`.
- The gate builds with warnings-as-errors and Swift 6 concurrency checks (a plain `swift build` can pass while the gate fails: e.g. deprecated `WKProcessPool`, `[weak self]` captures inside `Task`). Release builds: `swift build -c release --product BrowserApp` only (CoreChecks needs debug hooks).
- WebKit extensions: private/non-persistent data stores are "private browsing" for extensions (set `defaultWebsiteDataStore`, `hasAccessToPrivateData` only in tests); never call `loadBackgroundContent()` (crashes on 27.0.1). WebKit returns the FIRST data store made for an identifier in a process.
- Timing-sensitive tests: passkey page test needs the window to stay key; the UI self-test "window frame remembered" flaked once; both pass on re-run.
- Another job on this Mac (`/Users/kd/Developer/revolve/...`) sometimes eats RAM; not ours, do not touch.
- Scratch/benchmark helper scripts used this session live in `/tmp/claude-501/...` and the session scratchpad (not in the repo); `scripts/chrome-load-bench.py` is the one kept.
