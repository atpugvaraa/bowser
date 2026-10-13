# 010 — Open-source references for the Arc-style UI (2026-10-13)

**Rule for this project:** study behaviour and structure, then implement independently. Arc itself is off limits: its Terms of Use (start.arc.net/terms-of-use) forbid anyone who "decompiles, reverse engineers, or otherwise attempts to obtain the source code or underlying ideas" and forbid derivative works. The projects below are open source and are the legitimate source of "how do others do this".
**Licensing note:** GPL-3.0 code may be read freely; copying it into this private, undistributed app is allowed, but the combined work would then be GPL if it were ever distributed. Default: do not copy code, learn from it. MPL-2.0 (Zen) is file-level copyleft. Per-folder third-party licences apply inside these repos.

| Project | Engine / language | License | Why it is useful |
|---|---|---|---|
| **Nook** (github.com/nook-browser/Nook) | WebKit, Swift/SwiftUI, macOS 26+ | GPL-3.0 | Closest to our goal. Manager-based design: BrowserManager (coordinator), ExtensionManager (WKWebExtension), SplitViewManager, PeekManager (link peek), TabOrganizerManager, DownloadManager, WebViewCoordinator. Local Swift packages: NookTabsCore (tabs/spaces model), NookDesign, NookBlocker (filter lists + cosmetic filtering), NookTweaks (per-site tweaks for YouTube etc., a Boosts-like idea), NookUI. Sidebar-first. ~2k stars; development resumed Sept 2026 under a new maintainer. |
| **Ora** (github.com/the-ora/browser) | WebKit, Swift/SwiftUI/AppKit, macOS 15+ | GPL-3.0 | Features: Sidebar, Tabs, Launcher (command bar), Search, Privacy, Passwords, Player, Importer, Settings, FindInPage, History, Downloads; `Vendor/SplitView`; injected scripts in `Resources/WebScripts`. ~2.2k stars; README says not ready for daily use. |
| **Aura** (doorhinge-apps/Aura-Browser) | Swift, iOS/iPadOS/macOS/visionOS | open source (check repo) | Small, Arc-alternative; smaller codebase, good for a quick read. |
| **Zen Browser** (github.com/zen-browser/desktop) | Firefox 157 base | MPL-2.0 | The best-documented Arc-like behaviour: workspaces, split view, Glance (peek), compact mode, Essentials/pinned, "Mods" (Boosts-like). Docs at docs.zen-browser.app. Different engine, so for behaviour only. |

What to take from each for our three priorities
- **Sidebar and spaces:** Nook's tabs/spaces package split and Ora's Sidebar/Tabs folders show how others separate model from view; Zen's docs describe the user-visible behaviour (space switching, pinned vs unpinned areas, compact mode).
- **Boosts:** Nook's NookTweaks (site-specific tweaks) and Zen Mods (user CSS/JS per site) are the closest public analogues; our version will be per-site user CSS/JS stored per space and injected as user scripts.
- **Split view / peek (later):** Nook's SplitViewManager and PeekManager, Ora's Vendor/SplitView, Zen's split view and Glance.
- **Not found / unverified:** none of the sources I could read describe "Boosts" by that name outside Arc itself; Nook's and Ora's folder contents were read at directory level only (no code reviewed yet).
