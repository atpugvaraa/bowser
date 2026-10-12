# Architecture — PROPOSED (modular, SwiftPM packages + one app target)

Status: proposed 2026-10-12, awaiting approval. Baseline macOS 15.4+, Swift 6, AppKit shell (SwiftUI where it helps).

## Rules
1. Dependencies point **down only** (UI -> features -> core). `BrowserCore` imports nothing but Foundation.
2. Only `EngineWebKit` imports WebKit. Everything else talks to `BrowserEngine` protocols.
3. Every module is its own SwiftPM target with its own tests. No module reaches into another's internals.
4. Optional features are **plug-in modules** (`BrowserModule` protocol) so they can be added or removed without touching core.
5. Private APIs (user allowed) live ONLY in `PrivateSPI`, behind protocols, with `#available` guards and a kill switch, so an OS update can't break the rest.

## Modules
```
App (executable, signing/entitlements)
 └─ UI                  window, sidebar, address bar, settings  (AppKit)
     ├─ Features: Spaces, Downloads, Permissions, Find, History, Bookmarks   (each separate target)
     ├─ Lifecycle       hibernation, archiving policies, protected-tab rules
     ├─ Resources       CPU/mem/GPU/pressure monitor, budgets, benchmark harness
     ├─ Extensions      WKWebExtension host, popup/toolbar, permission review
     ├─ Media           PiP, media keys, audio indicator, AirPlay hooks
     ├─ Security        nav policy, TLS errors, permissions, credential/AutoFill/passkey glue
     ├─ Persistence     SQLite (GRDB-free: system SQLite3), migrations, crash-safe writes
     ├─ EngineWebKit    WKWebView, data stores, navigation delegate  (implements BrowserEngine)
     ├─ PrivateSPI      optional, isolated, guarded
     └─ BrowserCore     models + protocols: Space, Profile, Folder, Tab, TabState, BrowserEngine, Store, Clock
Diagnostics             logging, metrics, signposts (used by all)
Later plug-ins: Reader, PageSave, Notes, Boosts, DevTools, Sync
```

## Key design decisions
- **Tab model** implements `WKWebExtensionTab/Window` from day one (spike 001).
- **Profile = WKWebsiteDataStore(forIdentifier:)**; Space references a profile ID (spike: isolation verified).
- **Hibernation state machine** (Core): Active -> Recent -> Idle -> Hibernated -> Archived (+Loading, FailedRestore). Engine exposes `suspend() -> TabSnapshot` / `resume(snapshot)`; Lifecycle decides *when*, Engine decides *how*.
- **Persistence separate from engine data** (master prompt §18); secrets only in Keychain.
- **Observability first**: signposts + metrics emitted from every module; benchmark harness is a module, not an afterthought.
- **Tests**: unit per module with fake engine; integration with real WKWebView; soak harness; the `scrutinize` gate runs all.

## Build system
SwiftPM workspace for modules; Xcode project (needed for entitlements, signing, XCUITest) hosts `App`. Full Xcode install required before Phase 3.

## Open items
- Plug-in API shape (`BrowserModule`): minimal first (commands, sidebar panels, tab hooks, URL schemes); grow on demand.
- Entitlement route for passkeys; SIP/AMFI decision documented in `docs/security/` before any change.
