# Browser Master Prompt --- Arc UX, Safari Integration, Chrome-Class Development

## Mission

Build a high-quality, native-feeling macOS browser for Apple Silicon
that combines:

-   Arc's Spaces, sidebar, vertical tabs, favorites, folders, tab
    organization, automatic archiving, and Boosts.
-   Safari-like macOS integration, stability, battery-conscious
    behavior, and a native user experience.
-   Chrome-class website compatibility and developer tooling wherever
    technically feasible.
-   Robust automatic tab hibernation and resource management for
    sessions with 100--300+ tabs.
-   Apple's ecosystem features, including Handoff/Continuity, Keychain,
    passkeys, and optional browser-owned sync.
-   A carefully measured approach to memory, CPU, GPU-process memory,
    network use, startup time, and long-session stability.

Primary development hardware: MacBook Pro with Apple M3 Pro and 18 GB
unified memory.

Current pain point: Zen has unacceptable memory and GPU-process usage.
Do not reproduce that experience. Do not claim the new browser is more
efficient without measurements.

This is a real software project, not a mockup. Build a working browser
incrementally, test it, document limitations honestly, and keep the app
runnable throughout development.

------------------------------------------------------------------------

## 1. Required workflow: REA + Ghidra, no Hopper

Repository: https://github.com/morluto/rea

Use REA as the investigation toolkit and Ghidra as the native-binary
analysis provider. **Do not install, download, require, or depend on
Hopper.** If REA offers to install Hopper, decline that option and
configure the existing Ghidra installation instead.

REA is a reverse-engineering assistant/toolkit, not a browser engine or
browser starter template. Do not assume it contains reusable browser
implementation code.

### 1.1 Inspect the environment first

Before making changes:

1.  Inspect the project directory, existing source code, Git status,
    available build tools, and installed dependencies.
2.  Check Node.js and npm versions against REA's current requirements.
3.  Check whether Ghidra is installed and determine its exact version
    and path.
4.  Check whether a 64-bit JDK 21 or newer is installed and discover its
    path.
5.  Confirm that the Ghidra installation includes the native decompiler
    for this Mac's architecture.
6.  Inspect REA's current README and official setup documentation rather
    than relying on remembered commands.
7.  Never overwrite unrelated agent configuration or existing MCP
    servers without reviewing the proposed changes.

If REA, Ghidra, or Java is missing, report exactly what is missing and
provide the official installation instructions. Do not silently install
software or change system configuration without approval.

### 1.2 Configure REA for Claude Code and Ghidra

Use REA's current supported setup workflow. The expected workflow is
approximately:

``` bash
npx rea-agents@latest setup
```

Choose Claude Code, review the setup plan, configure Ghidra as the
native analysis provider, and explicitly decline Hopper installation.
Use the exact provider-selection procedure documented by the current REA
release.

For a Ghidra installation, REA's current documentation describes setting
the paths before running setup, for example:

``` bash
export GHIDRA_INSTALL_DIR="/absolute/path/to/ghidra_12.1.4_PUBLIC"
export JAVA_HOME="/absolute/path/to/jdk-21"

npx -y rea-agents@latest doctor --provider ghidra --json
npx rea-agents@latest setup
npx -y rea-agents@latest doctor --json
```

Replace example paths with actual discovered paths. Do not copy these
example paths literally unless they match the machine. If the installed
REA release uses a different version or command, follow its current
documentation.

Restart Claude Code after setup. Verify that the REA MCP server and its
investigation workflow are visible to Claude Code. Use REA's
provider/capability diagnostics to confirm that Ghidra is selected and
Hopper is not required.

Do not mark setup complete until diagnostics pass or remaining
limitations are explicitly documented.

### 1.3 Use REA purposefully

Use REA to investigate the behavior and architecture of locally
available, authorized applications and to gather evidence about features
we want to reproduce.

Priority targets: - Arc: Spaces, sidebar, tab lifecycle, favorites,
folders, tab archiving, Boosts, quick search, split view, and navigation
behavior. - Safari: native macOS integration, WebKit-related behavior,
battery-conscious operation, tab management, extension model,
Handoff-related behavior, and system integration. - Chrome: DevTools
workflows, browser behavior, extension concepts, developer workflows,
and web compatibility. - Firefox: WebExtensions concepts and user-facing
behaviors relevant to extension compatibility.

Investigation rules: - Start with official documentation, observable
runtime behavior, and REA evidence. - Use Ghidra only when native-binary
analysis is genuinely useful to answer a specific question. - Use REA's
read-only Ghidra capabilities for functions, strings, symbols, assembly,
decompilation, calls, references, and other supported evidence. - Treat
decompiler output as pseudocode, not recovered original source code. -
Do not assume REA/Ghidra can manipulate the target application's GUI or
modify its binary. - Do not bypass licensing, access controls, security
boundaries, or authorization. - Do not copy proprietary code, assets,
icons, branding, or protected implementation details. Recreate observed
user-facing behavior independently. - Record evidence, confidence, and
limitations. Clearly label hypotheses. - If a feature can be implemented
from public APIs and normal testing, do not delay implementation for
deeper reverse engineering. - Do not let reverse engineering consume the
project. Complete a bounded research phase and then build.

Produce `docs/research/` notes for findings, with: - Question
investigated. - Method and tools. - Evidence or references. - Observed
behavior. - Confidence level. - Unknowns and limitations. -
Implementation implications.

------------------------------------------------------------------------

## 2. Architecture decision: WebKit first, but evidence-driven

Before substantial implementation, compare two engine paths and create
`docs/architecture/engine-decision.md`.

### Option A: WebKit / WKWebView

Use Swift, SwiftUI, AppKit, and WKWebView where appropriate.

Potential advantages: - Native macOS integration. - Access to Apple's
supported web-rendering framework. - A promising foundation for
battery-conscious behavior. - Integration with native system UI,
Keychain, authentication APIs, and Continuity APIs. - A natural route to
supported Safari Web Extension approaches, subject to API compatibility.

Limitations: - WebKit does not automatically provide Chrome DevTools. -
Chrome-specific APIs and rendering behavior may differ. - Firefox and
Safari extensions cannot simply be installed wholesale. - WebKit is not
guaranteed to use less memory or GPU resources for every workload. -
WKWebView does not expose every control available to Safari itself.

### Option B: Chromium

Evaluate an embedded Chromium architecture if hard requirements cannot
be delivered satisfactorily with WebKit.

Potential advantages: - Strong alignment with Chrome rendering behavior
and website compatibility. - A more direct foundation for Chromium-style
extension APIs and debugging workflows.

Limitations: - More integration, distribution, update, and maintenance
complexity. - Embedding Chromium does not automatically provide all of
Chrome's services, extension-store behavior, branding, or proprietary
features. - Low battery use and low memory use still require measurement
and optimization.

### Decision rules

Compare: - Memory and GPU-process memory. - CPU utilization and battery
impact. - Long-session stability. - Page loading on ordinary and slow
networks. - Compatibility with complex web apps. - DevTools
feasibility. - Extension API feasibility. - macOS system integration. -
Engineering effort and ongoing maintenance.

Start with WebKit unless the investigation shows a mandatory requirement
cannot reasonably be met. If exact Chrome DevTools behavior and Chrome
extension compatibility are hard requirements, reassess Chromium before
building too much.

Do not build two complete rendering engines in version one. Keep the
browser UI, lifecycle manager, persistence, profiles, and
engine-specific functionality behind clear interfaces so an engine
change remains possible.

Never claim that WebKit automatically guarantees Safari's battery life
or Safari's complete behavior. Benchmark the actual application.

------------------------------------------------------------------------

## 3. Product principles

1.  **Stability over feature count.**
2.  **Memory efficiency over keeping every renderer alive.**
3.  **Restoreability over silently losing state.**
4.  **Native macOS behavior over imitating platform conventions
    poorly.**
5.  **Evidence over assumptions.**
6.  **Privacy and profile isolation by design.**
7.  **Measurable performance over marketing claims.**
8.  **A functioning browser before decorative polish.**
9.  **No false claims:** mark features as implemented, partial, blocked,
    or not implemented.
10. Keep the application runnable and compile/test after small,
    reviewable changes.

------------------------------------------------------------------------

## 4. Arc-style Spaces and profile/account assignment

Spaces are a core requirement.

Implement independent browsing workspaces such as Work, Research,
Personal, and Projects. Each Space should preserve: - Its tab list and
tab ordering. - Pinned tabs and favorites. - Nested folders. - Sidebar
state. - Saved-session metadata. - Optional visual identity. - Optional
browser-profile assignment. - Space-specific behavior and exceptions.

Allow users to create, rename, reorder, duplicate, archive, and delete
Spaces. Make switching fast and keyboard accessible.

### Profiles and accounts

A Space may be associated with a browser profile. Profiles must provide
real isolation for: - Cookies and authenticated sessions. - Local
storage and IndexedDB. - History and permissions where appropriate. -
Extension configuration where supported. - Cached data where
appropriate.

Use the engine's supported profile/data-store architecture. Do not treat
a different sidebar color as a security boundary.

Never move URLs into a different authenticated profile without clear,
safe behavior. Never expose cookies, credentials, or tokens between
profiles.

If the chosen engine cannot safely host separate profiles in one
process, use separate contexts or processes where appropriate and
document the resource trade-off.

------------------------------------------------------------------------

## 5. Sidebar, vertical tabs, folders, and navigation

Build an Arc-inspired sidebar with: - Vertical tabs. - Favorites at the
top. - Pinned tabs. - Nested folders where practical. - Drag-and-drop
organization. - Multi-select and bulk actions. - Tab context menus. -
Tab search across all Spaces. - A keyboard-driven command palette. -
Split view. - Peek-style link previews where technically feasible. -
Duplicate-tab detection. - Quick switching between Spaces and tabs. -
Light and dark appearance. - Native accessibility and keyboard behavior.

Example:

``` text
Work
  Favorites
    GitHub
    Google Docs
    AWS Console
  Project Alpha
    Documentation
    Pull Requests
    Dashboard
  Project Beta
    Repository
    Issue Tracker

Research
  Papers
  Documentation
  Experiments

Personal
  Favorites
  Reading
```

Folders must be persistent organizational objects, not just visual
separators.

### Existing-tab behavior

When a URL is already open, offer configurable behavior: - Switch to the
existing tab. - Open a new tab. - Open a duplicate in the current
Space. - Reuse a tab in the selected folder.

Normalize URLs conservatively. Do not merge pages whose paths, query
parameters, or authentication contexts materially differ.

------------------------------------------------------------------------

## 6. Favorites, bookmarks, pinned tabs, and saved sessions

Implement: - Sidebar favorites. - Nested bookmark/favorite folders. -
Custom names and icons. - Drag-and-drop organization. - Space-specific
favorites if practical. - Import/export using supported bookmark
formats. - Pinned tabs. - Named sessions. - Save and restore a complete
Space. - Lazy restoration so all pages do not load at startup.

Pinned tabs must not be automatically archived unless the user
explicitly enables such a policy.

Keep browser metadata and renderer state separate. Make saved sessions
resilient to application crashes and interrupted writes.

------------------------------------------------------------------------

## 7. Automatic tab hibernation

This is a core product feature and must not be postponed until the end.

Implement a real lifecycle manager. Hiding a view or setting its opacity
to zero does not prove memory has been released.

Suggested states: - Active. - Recently used. - Idle. - Eligible for
hibernation. - Hibernated. - Archived. - Loading. - Failed to restore.

Configurable controls: - Inactivity timer. - Memory-pressure-aware
policy. - Maximum number of live page instances. - Per-Space
exceptions. - Per-site exceptions. - Protected tabs. - Manual
hibernate. - Hibernate all inactive tabs. - Restore on selection. - Lazy
loading when restoring sessions.

Suggested behavior: - Keep the visible tab responsive. - Give recently
used tabs a grace period. - Hibernate eligible inactive tabs after a
configurable delay. - Become more aggressive when macOS memory pressure
increases. - Keep archived tabs lightweight until restored.

### Correct engine-specific implementation

For WebKit, investigate whether inactive WKWebView instances can be
safely destroyed and recreated while preserving the required website
data store and session metadata. Use supported APIs. Do not assume a
hidden WKWebView releases its memory.

For Chromium, investigate supported page lifecycle, process, and discard
mechanisms before creating custom behavior.

Preserve, where possible: - URL and navigation history. - Tab order,
Space and folder membership. - Profile association. - Scroll position. -
Form state when it can be saved safely. - Restoration metadata.

Do not promise perfect recovery of arbitrary JavaScript heap state after
destroying a renderer.

Protect active calls, media playback, recording, uploads, downloads,
unsaved forms, and other important work. Explain why a protected tab
cannot be hibernated.

------------------------------------------------------------------------

## 8. Automatic archiving: separate from hibernation

Archiving removes an old tab from the active sidebar; hibernation frees
page resources while the tab remains visible in its current
organization.

Implement: - Configurable inactivity period before archival. - Optional
maximum active-tab count. - Per-Space rules. - Exclusions for pinned
tabs, selected sites, and protected activities. - Searchable archive
with filters. - One-click restoration. - Bulk restore and delete. -
Undo. - Optional metadata retention period. - Preservation of URL,
title, favicon metadata, timestamps, source Space, folder, and profile
reference.

Never silently delete favorites or bookmarks during archival. Avoid
archiving tabs performing important active work. Do not conflate
archival with browser history deletion.

------------------------------------------------------------------------

## 9. Resource manager and diagnostics

Build a resource manager that considers the whole browser, not just
renderer memory.

Report where measurable: - Total browser process memory. -
Web-content/renderer memory. - GPU-process memory. - CPU activity. -
Memory pressure. - Swap usage where available. - Number of live, idle,
hibernated, and archived tabs. - Restoration latency. - Last-used
time. - Background network activity where measurable.

Distinguish direct measurements from estimates and unavailable values.
Never fabricate metrics or label an estimate as exact.

Use public macOS APIs and supported engine instrumentation. Do not use
private APIs.

Implement: - Bounded caches. - Efficient favicon/thumbnail caching. -
Lazy loading of inactive Spaces. - Avoidance of unnecessary polling. -
Cleanup of obsolete renderer instances. - Crash-safe session
restoration. - Memory-pressure notifications where supported. -
Battery-aware behavior on battery power.

Do not aggressively throttle pages that need to remain active.

------------------------------------------------------------------------

## 10. Safari-like macOS integration

Use native macOS conventions where they improve reliability and
predictability: - Native menus and keyboard shortcuts. - Standard
file-open and download dialogs. - Finder integration for downloads. -
Native sharing. - Native notifications where appropriate. - System
appearance and accessibility settings. - Window restoration. - Secure
storage. - Public permission APIs.

Avoid excessive blur, transparency, continuous animation, or other UI
effects that cost resources without improving usability.

Do not use private macOS APIs to control other applications or bypass
browser security.

------------------------------------------------------------------------

## 11. Apple Handoff, Continuity, and cross-device browsing

Implement Apple's supported Handoff/Continuity behavior where public
APIs permit it.

Investigate and use appropriate public APIs, including `NSUserActivity`
where applicable, to: - Advertise an eligible current browsing
activity. - Continue a page from this Mac to a compatible iPhone, iPad,
or another Mac. - Receive a compatible activity from another device. -
Restore the URL and safe browsing context. - Handle disabled Handoff,
unavailable devices, account mismatches, and restoration failures.

Do not send passwords, cookies, access tokens, or private browsing data
through Handoff metadata.

Distinguish: 1. Native Apple Handoff/Continuity. 2. Browser-owned
cross-device tab/session sync.

Do not claim that a custom browser automatically participates in every
Safari-only Continuity feature. Verify actual behavior on physical
devices.

------------------------------------------------------------------------

## 12. Optional iCloud/browser sync

Design optional synchronization for users signed into the same Apple
Account. Investigate CloudKit or other appropriate public
Apple-supported mechanisms, subject to entitlements and distribution
requirements.

Potential sync targets: - Spaces and their organization. - Favorites and
folders. - Saved sessions. - Open-tab metadata. - Archived-tab
metadata. - Selected preferences. - Portable Boost and extension
settings where safe.

Requirements: - Optional and clearly explained. - Offline support and
eventual synchronization. - Deterministic conflict resolution. - No data
loss just because a device is temporarily offline. - Respect profile and
private-browsing boundaries. - Never sync passwords, cookies,
authentication tokens, or sensitive session data through ordinary tab
metadata. - Document required developer account, entitlements, signing,
and distribution limitations.

Do not assume the app can access Safari's private iCloud browsing
database or reuse Safari's internal session state.

------------------------------------------------------------------------

## 13. Keychain, credentials, passkeys, and AutoFill

Use macOS Keychain Services and supported authentication frameworks.

Requirements: - Secure credential storage/retrieval using public APIs. -
Appropriate access groups and entitlements. - Profile-aware access
controls. - Explicit credential deletion and cleanup. - Touch ID or
user-presence checks where supported and appropriate. - No passwords in
plaintext, logs, analytics, or ordinary SQLite tables. - No silent
import of credentials from another browser. - Explicit, user-consented
credential import if supported.

Investigate `AuthenticationServices` and supported system interfaces
for: - Passkey authentication. - System credential suggestions. -
Password manager integration. - AutoFill where compatible with the
selected engine.

Never implement custom passkey cryptography or intercept authentication
secrets. Do not promise direct access to Safari's private credential
database.

Test sign-in, credential retrieval, passkeys, deletion, sign-out, and
profile isolation on supported macOS versions.

------------------------------------------------------------------------

## 14. Arc-style Boosts

Implement per-site customizations: - CSS injection. - Optional
JavaScript injection. - Site matching rules. - Enable/disable
controls. - Per-Space settings. - Import/export. - Preview and reset. -
Editor with syntax highlighting where practical.

Boosts may hide or restyle page elements and automate personal
workflows. Treat custom JavaScript as potentially untrusted: - Ask for
clear permissions. - Scope it to selected websites. - Do not grant
access to browser internals, other profiles, passwords, or unrelated
tabs. - Do not execute arbitrary imported scripts silently. - Explain
the capabilities of each Boost.

Use supported engine APIs and document differences between WebKit and
Chromium injection mechanisms.

------------------------------------------------------------------------

## 15. Extension compatibility: Safari and Firefox

The goal is broad compatibility with useful Safari Web Extensions and
Firefox WebExtensions, but do not promise that every extension works
unchanged.

First document a supported WebExtensions API target and a compatibility
matrix.

Investigate: - Content scripts. - Declarative content modification. -
Storage. - Context menus. - Tabs and navigation. - Request filtering
where supported. - Permissions. - Keyboard commands. - Popup
interfaces. - Background execution and lifecycle. - Extension updates
and trust.

Prioritize the APIs that provide the most value for the target audience.

Do not claim that Firefox-specific APIs or native messaging
automatically work inside WebKit. Implement an adapter only where
behavior can be correct and secure.

Support trusted manual installation where feasible, with permission
review, source/signature verification as appropriate, and clear
warnings.

If broad extension compatibility proves to be a hard requirement that
WebKit cannot meet, revisit the engine decision before expanding the
extension implementation.

------------------------------------------------------------------------

## 16. Chrome-class developer experience

Developer workflows are a major requirement.

Implement or integrate the best supported tools for the chosen engine: -
DOM inspection. - CSS inspection and live editing. - JavaScript
console. - Network request inspection and waterfall. - Performance
profiling. - JavaScript breakpoints. - Source maps. - Storage/cookie
inspection. - Device emulation where supported. - Request blocking and
overrides where supported. - Error/warning reporting. - Local
development server workflows. - Familiar keyboard shortcuts. -
Detachable tools or split-panel layout where practical.

For WebKit, use Web Inspector and supported interfaces as the baseline.
Do not claim this is Chrome DevTools or fully compatible with Chrome's
debugging protocols.

If actual Chrome DevTools compatibility is mandatory, evaluate Chromium
before major implementation. Document exactly which features work and
which do not.

------------------------------------------------------------------------

## 17. Slow-network performance

Optimize for both ordinary and slow/high-latency connections.

Measure: - Cold and warm navigation. - Time to first render. - Time to
usable interaction. - Request count and transferred bytes. - Cache
effectiveness. - Background traffic. - Restoration latency for
hibernated tabs. - Failure and retry behavior. - Effects of content
blocking.

Avoid unnecessary prefetching by default, especially if it wastes
bandwidth or battery. Allow configurable data-saving behavior.

Implement configurable content blocking where feasible. Avoid breaking
sites unnecessarily.

Test on a normal connection and a reproducibly throttled connection. Do
not call a browser faster solely because it blocks more content; report
compatibility and bandwidth effects too.

------------------------------------------------------------------------

## 18. Persistence and data integrity

Use an appropriate transactional local store such as SQLite for: -
Spaces. - Profile metadata. - Tab metadata. - Folders. - Favorites. -
Archived tabs. - Saved sessions. - Boost configuration. - Preferences.

Use schema migrations, crash-safe writes, and recovery after interrupted
operations.

Keep browser metadata separate from engine profile data. Use Keychain
for secrets. Preserve user data across upgrades. Test import/export and
restoration.

------------------------------------------------------------------------

## 19. Security and privacy

Treat this as a security-sensitive application.

Implement: - Real profile isolation. - Secure credential storage. - Site
permissions. - Safe download handling. - Normal TLS/certificate
validation. - Private browsing with explicit persistence rules. - Safe
extension and Boost execution. - Protection against cross-profile
access. - Clear user permission prompts. - No telemetry by default
unless explicitly designed and disclosed.

Never disable sandboxing to simplify implementation. Do not bypass
access controls or use private APIs.

Only investigate applications and binaries the user is authorized to
analyze. REA/Ghidra findings must inform an independent implementation,
not copying proprietary code.

------------------------------------------------------------------------

## 20. UI and interaction design

Make the browser feel native to macOS while using Arc-inspired
organization: - Compact, refined sidebar. - Clear
active/hibernated/archived/pinned states. - Smooth but restrained
transitions. - Light and dark modes. - Accessible contrast and keyboard
navigation. - Good empty, loading, error, and restore states. - A
sidebar that remains usable with 100--300 tabs. - Clear profile and
Space indicators.

Do not copy Arc branding, icons, or proprietary assets. Build an
original visual identity.

------------------------------------------------------------------------

## 21. Performance testing and acceptance

Establish measured baselines before promising numerical targets.

Create a repeatable test harness for: - Cold/warm launch. - Navigation
and reload. - Back/forward. - Tab switching. - Space switching. -
Session restore. - Hibernation and restoration. - Archiving and
restore. - Extension and Boost execution. - Memory pressure. - Long
sessions.

Test workloads: 1. 20 tabs, several active. 2. 50 tabs across multiple
Spaces. 3. 100 tabs with around 20 frequently used. 4. 200 primarily
inactive tabs. 5. A mixed session with GitHub, documentation, ChatGPT,
YouTube, and complex web apps. 6. A session with extensions and Boosts.
7. A session lasting at least four hours.

Where possible, compare on the same Mac against Safari, Arc, and one
Chromium browser. Record macOS/browser versions, extensions, URLs,
network conditions, and methodology.

Measure: - Startup latency. - Navigation and interaction latency. -
Total browser memory. - Renderer memory. - GPU-process memory. - CPU
utilization. - Memory pressure and swap. - Battery impact. - Memory
reclaimed by hibernation. - Restore latency. - Crash rate and failed
restorations.

Do not invent results. If a metric cannot be measured, mark it
unavailable. RSS may count shared memory and must not be presented as
exact memory returned to macOS.

After baseline measurements, define performance targets and regression
thresholds. Test that new features do not cause sustained memory growth,
UI stalls, or resource leaks.

------------------------------------------------------------------------

## 22. Phased implementation

Keep the application runnable at each phase.

### Phase 0 --- Research and architecture

-   Inspect REA, Ghidra, Java, the repository, and build environment.
-   Configure REA + Ghidra for Claude Code; no Hopper.
-   Investigate Arc/Safari/Chrome behavior within a bounded scope.
-   Create evidence notes and the engine decision record.
-   Identify API and distribution risks.

### Phase 1 --- Functional browser core

-   Native application shell.
-   Address/search bar.
-   Back, forward, reload, navigation progress.
-   Real page rendering.
-   Create/close/reorder/switch tabs.
-   Persistent history and bookmarks.
-   Basic profile persistence.

Deliver a functioning browser, not a mockup.

### Phase 2 --- Arc-style organization

-   Spaces.
-   Vertical tabs.
-   Folders.
-   Favorites.
-   Pinned tabs.
-   Profile assignment.
-   Duplicate-tab behavior.
-   Saved sessions and keyboard navigation.

### Phase 3 --- Hibernation and archive

-   Real hibernation.
-   Memory-pressure-aware policies.
-   Lazy restoration.
-   Automatic archiving.
-   Protected tabs and exclusions.
-   Diagnostics panel.
-   Long-session tests.

### Phase 4 --- Apple ecosystem

-   Keychain.
-   Passkey/AuthServices integration.
-   Handoff.
-   Native file/share/permission flows.
-   Optional browser-owned sync, subject to entitlements and
    feasibility.

### Phase 5 --- Boosts and extensions

-   CSS/JS customization.
-   Security and permission model.
-   Extension compatibility matrix and supported APIs.

### Phase 6 --- Developer tools

-   Integrate Web Inspector or an appropriate engine-specific tool.
-   Add network/performance/debugging features.
-   Revisit Chromium if compatibility requirements are not met.

### Phase 7 --- Hardening

-   Benchmark and profile.
-   Fix memory growth and resource leaks.
-   Test slow network.
-   Test crash recovery and persistence.
-   Accessibility, UI polish, and regression testing.

Do not declare a phase complete unless its functionality is implemented
and its relevant tests pass.

------------------------------------------------------------------------

## 23. Repository and engineering discipline

Before editing: - Inspect the existing repository and Git status. -
Preserve existing working code. - Avoid destructive operations. -
Explain major dependencies and architecture choices. - Never replace the
whole project without justification.

Maintain: - `README.md` - `docs/architecture/` - `docs/research/` -
`docs/testing/` - A setup guide. - Benchmark methodology and reports. -
Known limitations. - An implementation checklist.

Use small, reviewable changes. Compile and test frequently. Do not add
large dependencies without explaining why. Do not fabricate completed
functionality.

If blocked by an unavailable API, entitlement, or framework limitation,
explain it and provide a realistic alternative.

------------------------------------------------------------------------

## 24. First response and start procedure

Begin by inspecting the project and local environment. Do not
immediately generate a large amount of code.

Return: 1. What REA can and cannot do for this project. 2. Whether REA +
Ghidra is correctly installed for Claude Code, with no Hopper
dependency. 3. The WebKit-versus-Chromium decision and evidence. 4. The
proposed architecture and major risks. 5. The first small implementation
milestone.

Then begin implementation, run tests, fix failures, and report exactly
what works.

Do not stop after writing a plan or a mockup. Continue until a
functioning browser core is running.

## Final product goal

Build an original macOS browser that feels as organized as Arc,
integrates with Apple platforms as naturally as practical, offers
Chrome-class development workflows where feasible, and keeps 100+ tabs
manageable through reliable automatic hibernation and archiving.

The defining promise is not simply "low RAM." It is **stable
long-session performance, responsive tab switching, reliable
restoration, controlled GPU/CPU use, battery-conscious behavior, and
trustworthy Apple ecosystem integration**.

The browser should prioritize correctness, security, data integrity, and
measured performance over feature count.
