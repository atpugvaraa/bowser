# 005 — Signing, passwords/passkeys, extension engine (plan, 2026-10-13)

## Facts found (sources are web search results; verify the Apple-gated parts before relying on them)
- Passkeys/WebAuthn for a third-party macOS browser need `com.apple.developer.web-browser.public-key-credential` (Apple docs page for the entitlement). It is Apple-gated: requested through the Apple Developer Program by the Account Holder and approved by Apple; individual memberships are reported as often declined (unofficial notes). Chrome/Arc/Zen/Orion hold it.
- Password AutoFill: Apple documents an **iCloud Passwords browser extension** for Chromium browsers (Chrome, Edge, Brave, Opera, Arc) on macOS ("Get Passwords extensions for a third-party browser", Apple Support), not Firefox. A Chromium extension that talks to a native helper through `nativeMessaging`. Plain WKWebView password AutoFill is reported unreliable in third-party WKWebView browsers (origami-browser #2).
- WKWebExtension (macOS 15.4+) loads Chrome-style manifests (MV2 and MV3) and exposes both `browser.*` and `chrome.*`. Known gaps (my spike + forum reports): no `offscreen`, `userScripts`, `downloads`, `history`, arbitrary `nativeMessaging`; `declarativeNetRequest` `modifyHeaders` unsupported; non-persistent background cannot use `webRequest` listeners.
- Local state: Xcode 27 installed, license accepted, **0 code-signing identities, 0 provisioning profiles** (no Apple ID signed in to Xcode yet).

## Signing (what the owner must do, ~5 min, then I automate)
1. Xcode > Settings > Accounts > add Apple ID. A free "Personal Team" gives a development certificate: enough for a stable signed `Browser.app` (keychain prompts stop, camera/mic usage strings work, notarization not needed for local use).
2. Passkeys: paid Developer Program ($99/yr) AND Apple approval of the public-key-credential entitlement (request form via the Account Holder). Until then passkeys are unavailable; passwords still can work (below). Provisioning of the entitlement needs a profile that carries it: cannot be self-signed unless AMFI is relaxed (owner pre-approved this, documented as last resort; not touched so far).
3. I will then: add `app/BrowserApp/Browser.entitlements` (sandbox off, `com.apple.security.device.camera/audio-input`, network client, the passkey entitlement when granted), Info.plist usage strings, flip `MediaDevicesEnabled`, make `build-app.sh` sign with `codesign --options runtime`, and add a signed-launch UI self-test.

## Passwords — layered, cheapest first
1. **System AutoFill in WKWebView** (free, no extension): test with a signed build on real login pages; record what appears.
2. **iCloud Passwords extension through the extension engine** (the Apple-endorsed route for non-Safari browsers). Needs our host to provide `nativeMessaging` to Apple's helper. Open question to verify on this Mac: where the helper lives and whether a non-Chrome host may invoke it. Will inspect only Apple's own system path / the extension's manifest, never Chrome's data.
3. Fallback: Passwords app "Open Passwords" button + a built-in credential prompt using `ASAuthorizationController` password requests.

## Extension engine — design (modular, power-conscious)
Goal: Chrome (MV2/MV3 `.crx`, Web Store zips) and Firefox (`.xpi`, `browser_specific_settings`) extensions work, without extra idle power.
- **Loader**: folder / zip / CRX (strip header) / XPI (zip). Validate manifest, show the permission list, install per profile, grants explicit and revocable (no blanket host access; spec threat model).
- **Normalizer**: Firefox keys (`browser_specific_settings`, `applications`) ignored/mapped; MV2 persistent background rewritten to non-persistent when safe (else loaded on demand), `browser`/`chrome` namespaces both available.
- **Shim layer** (Swift handlers + injected JS polyfill, one module per API so each can be swapped): `downloads` (our DownloadCoordinator), `history`/`bookmarks` (our Store), `offscreen` (hidden WKWebView), `contextMenus`, `commands`, `declarativeNetRequest` (native content rules), `nativeMessaging` (allow-listed hosts only), `userScripts` (inject via WKUserScript). Unsupported API -> a clear logged error, never a silent no-op.
- **Power/CPU budget**: backgrounds are event-driven and unloaded when idle; per-extension memory cap reusing the memory watchdog; per-extension CPU sampling with a visible "this extension is using X%" and auto-suspend; extension content scripts only on granted hosts.
- **Compatibility matrix tests** (real extensions, local): uBlock Origin Lite (known: loads, did not block; root cause open), Dark Reader, Bitwarden, Vimium, Grammarly (needs the owner's login). Each: loads, popup works, content script runs, background wakes/sleeps, idle CPU ~0.
- Host UI: toolbar action buttons + popup window + permission sheet (plain AppKit).

## Order of work (after the soak finishes, to keep its numbers clean)
1 extension host skeleton + loader + normalizer + tests (no account needed) -> 2 shim modules + compatibility matrix -> 3 signing script ready for the owner's Apple ID -> 4 passwords layers 1-3.
