# Learnings (append as we go; date each)

## 2026-10-12
- REA + Ghidra: setup done for Claude Code (`rea-agents` 6.4.0, Ghidra 12.1.4, JDK 21 via `openjdk@21`; default `java` is 1.8, too old). Hopper declined/not installed. MCP tools appear after a Claude Code restart.
- REA setup flag: `--client claude_code` (not `claude`).
- Baseline (this Mac, one snapshot): Zen `plugin-container` ~2.0 GB RSS; Arc renderer helper ~2.6 GB. This is the pain to beat. Needs proper 100-tab measurement later.
- SDK has `WKWebExtension*` (macOS 15.4+). Needs Package platform `.macOS("15.4")`, tools-version 6.0.
- Spike: `WKWebExtension(resourceBaseURL:)` traps unless run inside a real `.app` bundle (bare SwiftPM binary crashes).
- Spike: MV3 content script injects fine; `runtime.sendMessage` fails "Tab not found" until the host registers tabs/windows (`WKWebExtensionTab/Window`, `didOpenTab`). => tab model must implement these from day one.
- No `timeout` on macOS; use `perl -e 'alarm N; exec @ARGV'`. Pipe output needs unbuffered stdout.
- Only Command Line Tools installed (no `xcodebuild`); SwiftPM + hand-made `.app` + ad-hoc codesign works for local use.
- Orion (WebKit) reportedly runs Firefox add-ons and uBlock Origin — to verify; study behavior only.

- Safari.app UI/extension host is closed; WebKit itself is open source. A WKWebView app inherits Safari's engine performance but not its shell.
- Project is now a git repo with a pre-commit gate (`scripts/gate.sh`: secret scan, build with warnings-as-errors, tests).

## Open questions
- Netflix 4K in a WKWebView app? Prime Video quality cap?
- Grammarly: does its Chrome/MV3 extension run under WKWebExtension? Apple Passwords: system AutoFill in WKWebView vs. needed entitlements.
- Does DRM video (Netflix/Prime/Disney etc.) play in a third-party WKWebView app? (test in core phase)
- Can WKWebExtension run MV2 uBlock Origin, or only uBO Lite (MV3)?
- Per-Space profile isolation via `WKWebsiteDataStore(forIdentifier:)`: verify.
- Best hibernation primitive for WKWebView (discard + snapshot vs process suspend).

## 2026-10-12 (Safari entitlements, via `codesign -d --entitlements`)
- Safari has 194 entitlements incl. `fairplay-client`, `com.apple.authentication-services.allow-authentication-request-any-rpid`, `...access-credential-identities`, `com.apple.private.extension-host.safari-extension`, `...can-interact-with-any-Safari-extension`, `com.apple.private.webkit.webpush`, `keychain-access-groups`. Private entitlements are restricted by macOS to Apple-signed binaries -> a custom browser cannot just claim them. Weakening SIP/AMFI would bypass this but is a system-wide security cost; not recommended.
- Implication: Netflix 4K (FairPlay path), Apple Passwords extension and Safari-extension hosting may be unavailable regardless of effort. Test, don't assume. WebContent processes in WKWebView are Apple-signed, so some FairPlay may still work (open).
- Master prompt bans private APIs; Ghidra-on-Safari use = read-only understanding for independent implementation.
- Probe: WKWebView host == Safari for FairPlay/HEVC/HDR/DV/AV1/VP9 capability. Netflix 4K on Mac is Safari-only per Netflix; Chrome Mac capped. Chromium is not a route to Netflix 4K. All third-party browsers (Chrome, Arc, Zen, Orion) hold `com.apple.developer.web-browser.public-key-credential` = passkey path is a public, Apple-granted browser entitlement.
- Macs: user wants support for macOS 14–27 (downgrade plans). `WKWebExtension` needs 15.4+, so macOS 14–15.3 would need a custom extension host or reduced extension support. Decide before Phase 2.
- User OK with weakening SIP/AMFI if documented with mitigations. Not done; nothing changed. Write docs/security/ before any change.

- Decision: macOS 15.4+ baseline (dropped macOS 14 as a requirement). Native WKWebExtension everywhere; older OS support later and optional. User dislikes macOS 26/27 memory use; baselines must be re-taken if the OS changes.
- Netflix (Standard plan) plays 1080p in a plain WKWebView app, with or without Safari-style UA; initial ramp 540p -> 1080p within ~30 s. 4K unverified (no 4K plan). Test harness: `spikes/video-test` (persistent login, logs `<video>` size to ~/Library/Logs/vt-video.log).
- YouTube 4K plays in plain WKWebView (3840x2160, near-zero drops). YouTube ignores programmatic quality setting; choose manually.
- 4K60 HDR AV1 plays correctly in plain WKWebView (HDR10 engaged). Observed lag = ~12 Mbps link, empty buffer. Use bandwidth as control when judging video lag. Dolby Vision only testable on Netflix/Apple TV+ DV titles (needs plan).
- Profile isolation PASS: `WKWebsiteDataStore(forIdentifier:)` gives separate cookies/localStorage per ID and vs default; persists across relaunch (spikes/profile-test). Basis for per-Space profiles.
- AirPlay API surface in WKWebView == Safari (`webkitShowPlaybackTargetPicker`, availability event). Real casting NOT tested (public network). Google Cast: no web sender API outside Chrome (`window.chrome` undefined); would need native Cast/DIAL work — later, optional.
- Link measured ~2 Mbps under contention (257 KB/s curl) / ~12 Mbps in YouTube stats: 4K HDR lag is the network.

## Scrutinizer review of spikes (2026-10-12) — result: PASS, no High
Spikes are throwaway. These patterns must NOT carry into product code:
- Popups loaded into the same view and no navigation scheme allowlist (video-test). Product: `decidePolicyFor` with allowlist; popups as new tabs.
- Logging page host/playback to disk on a timer (video-test). Product: no history in logs; debug-only/opt-in.
- Blanket `grantedExplicitly` for all extension permissions/match patterns (ext-spike). Product: user prompt/policy; never auto-grant optional/all-urls.
- String-interpolated JS (`evaluateJavaScript("...\(x)...")`). Product: `callAsyncJavaScript` with arguments.
- Unconditional `isInspectable = true`; `--eval` hook; force-unwrapped URLs from input; unretained-delegate fragility; repeating Timer capturing self.
- Fixed: server.py filename sanitized (path traversal) and Content-Length bounded.
- Data hygiene: the `vt` test app holds Netflix/YouTube logins in `~/Library/WebKit/dev.kd.vt` (+ Caches). Wipe when done testing.
