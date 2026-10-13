# Page appearance (light / dark) — feature note, 2026-10-13

- Websites see `prefers-color-scheme` from the web view's appearance. **Default: follow macOS** (including automatic sunset switching): pages start in the system mode and switch with it. Verified in real WebKit (EngineStress 10f) and against the live system setting.
- **Settings ▸ Websites use:** Follow system (default) / Always light / Always dark. The forced modes set the appearance of web views only; the browser's own UI keeps following the system. Applies live to open pages and to new tabs. UserDefaults key `pageAppearance` (`system|light|dark`).
- While a page loads, the area behind it uses the window background (`underPageBackgroundColor`), so there is no white flash in dark mode.
- Code: `EngineWebKit/PageAppearance.swift`, `WebKitTab.ensureLive`, `WebKitTabFactory.setPageAppearance`, `SettingsWindowController`.
- Limits: a site with its own saved theme (cookie / localStorage) may ignore the system scheme until its theme toggle is set to "device"; "force dark" is the page's own dark CSS, not an image-inverting filter (a Boosts-style forced dark filter is a later feature).
- Redesign: per-space tint and a toolbar toggle belong to the Arc-style redesign (docs/research/009).
