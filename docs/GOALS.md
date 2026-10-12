# Goals

Personal browser for one user (kd), Apple Silicon Mac (M3 Pro, 18 GB). Not for distribution.

## Primary use
Watching videos, browsing, research with many tabs (100+).

## Priorities (in order)
1. **Core browser, done very well** — stable, fast, correct. Everything later depends on it. Most time goes here.
2. **Hibernation, archiving, resource management** — second most time. Keep Arc's archiving idea; do better than Arc/Zen on hibernation and resource use. Measure everything.
3. **Extensions** — uBlock Origin, password manager, Firefox/Chrome extensions where feasible.
4. After 1–3: a working but plain-UI browser. Then Spaces/sidebar polish, Boosts, Apple integration, dev tools.

## Decisions (2026-10-12)
- **Baseline is Safari**, not Zen/Arc. Same WebKit engine, so engine efficiency is parity at best; wins come from hibernation/archiving policy and a lean shell. 8 h soak compared against Safari first, then Zen/Arc.
- Safari is weak at extension behavior, devtools, UI: those get the most original work.
- **Netflix 4K is a stretch goal**, tested in phase 0 (needs FairPlay + HEVC + HDCP 2.2; Netflix gates 4K to Safari). Report result honestly. Netflix, Prime, YouTube are the must-work video sites.
- Must-have extensions: **Grammarly**, **Apple Passwords** (neither has a confirmed path; spike in phase 0/5).
- Reader mode, page saving, notes: later, as separate SwiftPM modules, not in core.
- Full Xcode will be installed.
- **Scrutinizer:** `.claude/skills/scrutinize` + `scripts/gate.sh` (pre-commit hook). Nothing is committed or called done without it.

- **Platform:** macOS 15.4+ is the baseline; older versions best-effort, added later.

## Security stance
Personal use allows slack on distribution (no notarization, no App Store, ad-hoc signing, no multi-user hardening). It does **not** allow slack on browsing security: keep WebKit current via macOS updates, TLS errors never silently bypassed, per-site permission prompts, process isolation kept, no telemetry, no plaintext credential storage, safe-browsing on.

## Non-goals (for now)
Distribution, auto-update, Windows/Linux, App Store, accounts/sync servers.

## Success measures
- Video playback works on the sites I actually use (incl. DRM ones) — checked early.
- 100–300 tabs for 8 h: stable memory, no GPU runaway, instant tab switch, correct restore. Measured vs Zen/Arc/Safari baselines.
- No data loss across crash/relaunch.
- No efficiency claim without a measurement.

## Test-safety rules
- Machine is often on a public/shared network: **no AirPlay, Cast, mDNS scanning, or any device-to-device streaming/discovery tests** unless the user says it is a trusted network. Never record names of other people's devices.
- Local test servers bind to 127.0.0.1 only.
