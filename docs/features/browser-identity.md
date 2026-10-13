# Browser identity (User-Agent) — feature note, 2026-10-13

**Why:** a bare WKWebView sends `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)` with no `Version/x Safari/y` token. Many sites treat that as an unknown/old browser and serve legacy or "unsupported browser" pages (this is what made pages look old). The default is now Safari.

**What it does**
- Default **Safari**: the token `Version/<installed Safari version> Safari/605.1.15` is added to WebKit's own string (version read from the installed Safari, e.g. 27.0.1). Honest: same engine.
- Selectable in **Settings ▸ "Tell websites this browser is"**: Safari (default), Chrome 145, Firefox 145, Edge 145. Stored in UserDefaults key `browserIdentity` (`safari|chrome|firefox|edge`), survives restarts.
- Applies to all open tabs from their **next page load**, and to every new tab.
- Code: `EngineWebKit/BrowserIdentity.swift` (strings), `WebKitTab.ensureLive` (applies `customUserAgent`), `WebKitTabFactory.setIdentity` (live switch + Safari token), Settings row in `SettingsWindowController`.
- Tests: EngineStress 10e (all four strings in real WebKit, switching an open tab) and the user-agent check in 10d.

**Limits (be honest)**
- Chrome/Edge/Firefox are a disguise: the engine stays WebKit, `navigator.userAgentData` and Chrome-only APIs do not appear. Sites that feature-detect still see WebKit; sites that only check the name may behave better or worse.
- Versions are hard-coded (`chromeMajor`, `firefoxMajor`) and need an occasional bump.
- Global setting only. Not built yet: per-site or per-space identity, a "custom string" field, automatic fallback when a site shows an unsupported-browser page.

**Redesign notes:** when the Arc-style UI lands, move this to a per-site control in the address bar / site menu (Firefox-style "request desktop site / switch identity") and keep Settings as the default.
