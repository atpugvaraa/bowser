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
