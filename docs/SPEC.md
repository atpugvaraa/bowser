# Spec (Phase 1) — DRAFT for sign-off

Inputs: GOALS.md, PLAN.md, ARCHITECTURE.md, BROWSER_MASTER_PROMPT.md, research/001–002.
Status labels per feature: not implemented / partial / implemented / blocked. Nothing is "done" without its acceptance test passing.

## 1. Scope tiers
**Must (Phase 3 core)**
| ID | Requirement | Acceptance test |
|---|---|---|
| C1 | Tabs: create/close/reorder/switch, keyboard shortcuts | unit (tab model) + UI smoke |
| C2 | Address/search bar with safe URL normalization (no `javascript:`/`file:` from typed input unless explicit) | unit table of inputs |
| C3 | Back/forward/reload/stop, progress, title/favicon | UI smoke |
| C4 | Navigation policy: scheme allowlist, popups -> new tab, `target=_blank`, external-app links ask first | unit + manual |
| C5 | TLS errors: block page, no silent bypass; per-host temporary override requires explicit click | manual + unit |
| C6 | Permissions (camera/mic/location/notifications): per-site prompt, remembered per profile | manual |
| C7 | Downloads: save dialog/Downloads folder, quarantine flag, progress, no auto-open | integration |
| C8 | Find in page, zoom, print, fullscreen, PiP, media keys, audio-playing indicator | manual matrix |
| C9 | Video: YouTube 4K HDR, Netflix 1080p+ (4K if plan allows), no drops at playback | harness (done in spikes) |
| C10 | History + bookmarks (SQLite) | unit |
| C11 | Session restore and crash recovery (app kill -9, WebContent crash -> reload prompt) | integration kill tests |
| C12 | Per-profile data stores (identifier-based) | integration (spike passed) |
| C13 | Passwords/passkeys via system AutoFill + `web-browser.public-key-credential` | manual on real sites; entitlement route in docs/security |
| C14 | Observability: signposts + metrics for memory/CPU/GPU per tab | harness |

**Must (Phase 4)** hibernation (H1), archiving (H2), resource manager (H3), protected tabs (H4), soak vs Safari (H5).
**Must (Phase 5)** extensions (E1 host, E2 popup/action UI, E3 permission review, E4 install from folder/zip/CRX, E5 matrix incl. Grammarly + uBO + password manager).
**Later**: Spaces/sidebar/folders/favorites/split view/command palette, Handoff, iCloud sync, Boosts, devtools, reader/page-save/notes modules.

## 2. Data model (SQLite, schema-versioned)
`profile(id, name, store_uuid, created)` · `space(id, name, profile_id, order, ...)` · `folder(id, space_id, parent_id, name, order)` · `tab(id, space_id, folder_id, url, title, favicon_ref, state, last_active, pinned, order, scroll, interaction_state_blob)` · `archive(id, tab snapshot cols, archived_at, source_space/folder)` · `history(id, profile_id, url, title, visited)` · `bookmark(...)` · `permission(profile_id, origin, kind, decision)` · `setting(key, value)` · `schema_migration(version, applied)`.
Rules: WAL mode, transactions per user action, migrations forward-only with backup, secrets never in SQLite (Keychain), web data stays in WebKit stores.

## 3. Performance budgets (set AFTER baselines; placeholders)
Measured on this Mac vs Safari (same OS, same pages): cold launch, tab switch latency, restore latency of hibernated tab, memory per idle tab, total memory at 100/200 tabs, GPU-process memory, 8 h growth slope. Budget rule: **within Safari +10% at 100 tabs on memory; hibernated tabs free renderer memory (measured); no sustained growth >X MB/h** (X from baseline). No claims without `docs/results/` data.

## 4. Threat model (personal machine, public networks)
Assets: logged-in sessions, passwords/passkeys, browsing history, local files.
Threats and controls:
- Hostile web content -> WebKit process isolation, nav allowlist, no `evaluateJavaScript` on string-built input, inspector off by default in release.
- Network attacker (public Wi-Fi) -> normal TLS validation, HTTPS-first, no cert bypass, no ATS relaxation.
- Malicious/over-privileged extension -> explicit permission grants, no blanket host access by default, per-profile scoping, review UI.
- Cross-profile leakage -> separate data stores, URL handoff between profiles prompts.
- Local snooping/logging -> no URLs/hosts in logs by default, history in profile DB only, Keychain for secrets.
- Weakened SIP/AMFI (user-accepted) -> compensating controls documented in docs/security before use: FileVault on, keep Gatekeeper, only re-sign this app, auto-disable-on-update note, not used for general browsing outside this app, revert path documented.
- Supply chain -> pinned dependencies, no unreviewed third-party code, extension zips from official releases only.

## 5. Test strategy
Per-module unit tests (fake engine); integration with real WKWebView on localhost server; kill/crash tests; soak harness; scrutinize gate on every commit; results in `docs/results/`.

## 6. Open decisions needing the user
1. Approve this spec. 2. Passkey entitlement route (Apple application vs self-sign with AMFI relaxed). 3. Grammarly login for the extension test. 4. Safari baseline run window (needs ~1 h of idle machine, network light via local pages).
