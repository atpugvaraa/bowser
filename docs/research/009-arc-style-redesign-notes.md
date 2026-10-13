# 009 — Arc-style redesign: notes and decisions (2026-10-13)

Owner request: Arc's features and look (Chrome's UI is "boxy and old"; Safari's is more modern), plus system dark mode. "We redesign later."

**Decisions**
- No decompiling of Arc (proprietary, license forbids reverse engineering; not needed). Reproduce behaviour and look from public descriptions and the owner's description of what matters.
- Redesign happens after the engine/extensions/passkeys work; nothing here is built yet.

**Look (phase 1):** translucent sidebar (vibrancy), web page as a rounded card inset from the window edge, slim address bar at the top of the sidebar, colored spaces (per-space tint), controls that appear on hover, light/dark following macOS automatically (`NSApp.appearance = nil`), optional per-space dark tint and "force dark pages" toggle, 120 Hz-friendly animations.
**Behaviours (phase 2):** pinned tabs and a favorites row, tabs that auto-archive after N hours (engine already sleeps/archives and never destroys), command bar on ⌘T (QuickOpen exists), drag to reorder (not built), per-space profiles (exists).
**Bigger features (phase 3):** split view, peek window for links, boosts (per-site CSS/JS — build on the extension engine), notes/easels.
**Already in place:** spaces, sidebar tabs, archive, quick open, windows restore, extensions button, identity setting (docs/features/browser-identity.md).
**Where UI lives today:** `app/Sources/BrowserApp/BrowserWindowController.swift` (buildUI), `MainMenu.swift`, `SettingsWindowController.swift`, `ExtensionsUI.swift`, `PasskeyUI.swift`.
