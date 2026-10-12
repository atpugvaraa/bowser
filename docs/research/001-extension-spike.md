# 001 — WKWebExtension spike

**Question:** Can a WKWebView-based browser run Chrome-style MV3 extensions?
**Method:** SwiftPM host (`spikes/ext-spike`), wrapped in a `.app` (a bare binary traps in `WKWebExtension.init`), macOS 27.0.1 / SDK 27, minimal MV3 extension (content script + service worker + storage).
**Observed:**
- Manifest v3 parses; content script injects on `http://127.0.0.1` (PASS).
- `runtime.sendMessage` content->background FAILED: "Tab not found". The host must register windows/tabs (`WKWebExtensionWindow`/`Tab` protocols, `controller.didOpenTab`) — a browser responsibility, not automatic.
- Manifest warning: missing `description`.
**Confidence:** high for the above; background<->content messaging untested until tab registration exists.
**Unknowns:** MV2 (uBlock Origin full), Firefox-only APIs, webRequest blocking, DNR, Chrome Web Store install flow, popup/action UI.
**Implications:** WebKit is viable for extensions; tab/window model must implement the extension protocols from day one. Next spike: register tabs, re-test, then load uBlock Origin Lite + Bitwarden.
**Reference (hypothesis, to verify):** Orion (WebKit) reportedly runs Chrome/Firefox extensions incl. uBlock Origin; study its public behavior, do not copy code.

## Update 2026-10-12: tab registration + API matrix (macOS 27.0.1, WKWebExtension)
- With `SpikeTab`/`SpikeWindow` registered (`didOpenWindow/didFocusWindow/didOpenTab/didActivateTab`) and controller delegate `openWindowsFor`/`focusedWindowFor`: content->background `runtime.sendMessage` **PASS**, `storage.local` PASS, 0 manifest errors.
- `chrome.*` namespaces PRESENT (manifest requested ~20 permissions, all declared perms granted): action, alarms, contextMenus, cookies, declarativeNetRequest, extension, i18n, menus, permissions, runtime, scripting, storage, tabs, webNavigation, webRequest, windows.
- ABSENT: bookmarks, browserAction, browsingData, commands, declarativeContent, devtools, dns, downloads, history, identity, idle, management, nativeMessaging, notifications, offscreen, omnibox, pageAction, privacy, proxy, search, sessions, sidePanel, tabGroups, theme, topSites, userScripts, webRequestBlocking.
- Caveats: absence may partly reflect the host not implementing delegates (e.g. nativeMessaging, notifications) rather than engine limits; MV3 only tested; no popup UI yet.
- Implication: MV3 ad blockers via declarativeNetRequest are plausible; extensions needing offscreen/identity/downloads/history/nativeMessaging will not work unless the host implements/adapts them.

## Update 2026-10-12: uBlock Origin Lite + DNR control
- uBO Lite 2026.1012.1545 (chromium zip from GitHub release; kept outside the repo) loads in WKWebExtension: 0 manifest errors, background loaded, all-URL access, injected content, content-modification rules present. Granted perms: activeTab, alarms, declarativeNetRequest, scripting, storage, unlimitedStorage. Its `offscreen` and `userScripts` permissions are NOT supported by WebKit (absent from granted set).
- **Control:** my own one-rule static DNR extension (`spikes/ext-spike/dnrext`) **blocks** `fetch` to the ad host (TypeError) => WebKit DNR blocking works through a minimal host.
- **uBO Lite did NOT block** in the same harness (fetch + script tags; identical to no-extension baseline). Cause UNDETERMINED. Hypotheses: relies on offscreen/userScripts or install-time (`runtime.onInstalled`) init; localhost treated as trusted; ruleset enable logic. Next: enable `ctx.isInspectable` and read its background console via Web Inspector; test on a non-localhost origin.
- Status: uBlock Origin Lite = BLOCKED/UNKNOWN pending investigation; DNR engine support = confirmed. Grammarly, Bitwarden = not yet tested (Grammarly needs an account login).
