# 006 — Extension privacy and install-safety audit (2026-10-13)

Independent reviews (two subagent passes) of the loader, downloader, CRX verifier, host and install UI. Findings fixed unless listed under "Accepted / open".

## What an extension can do (by design) and what stops it
| Risk | Control | Evidence |
|---|---|---|
| Hostile package (zip-slip, symlinks, bombs) | name checks, symlink refusal before and after unzip, size/entry caps, atomic staging, content-hash install folders (no merging) | CoreChecks s.35 |
| Tampered / re-packed Chrome file | CRX3 developer signature must verify; the id is derived from the signing key and is the install id; CRX2 (unsigned) refused | s.35-36 + live downloads |
| Wrong extension from the store | requested id must equal the signing-key id; HTTPS only, official hosts only, redirects re-checked | s.36 |
| Silent over-grant | the install prompt lists EVERY host pattern and permission (scrolling), flags broad hosts (`<all_urls>`, bare `*`, wildcard on a TLD), grants exactly what was listed; replacing an installed id says "Replace" and flags extra access | s.35b, ExtensionsUI |
| Prompt spoofing | name/version/notes stripped of control and bidi characters and truncated; id shown | s.35b |
| Spying on account pages | blocklist (Apple ID / iCloud by default, `extensionBlockedSites` default key) denied explicitly incl. subdomains and trailing-dot forms; an `<all_urls>` extension gets nothing there | EngineStress (real WebKit, positive control) |
| Reaching other apps | WebKit exposes no `nativeMessaging`; no permission-prompt delegate, so optional permissions are denied | spike API table, host has no such delegate |
| Private browsing | extensions never get private-data access in the product | `hasAccessToPrivateData = false` |
| Cross-profile peeking | each profile has its own controller, storage and data store; a controller only sees windows of its own profile | ExtensionHost.windows(for:) |
| Auto-update swapping code | no auto-update; `update_url` stripped | normaliser |

## Accepted / open (honest)
- An extension you approve for all sites can read what you type there (passwords included). Nothing in WebKit lets me prevent that; the prompt says so. Use the blocklist for sensitive sites.
- Firefox downloads: the sha256 and the file URL come from the same add-ons API response, so it protects against transit/CDN corruption, not a compromised API. The XPI's Mozilla signature is not verified yet.
- `extensions.json` (grants) has no integrity protection against a process running as you; same-user malware can do worse anyway. Folders are content-hash addressed, so a swapped folder is a different install.
- Extensions are loaded in every profile once installed; per-space enablement is not built.
- unzip size cap trusts the archive's own sizes; a lying archive is bounded by the 60 s kill and disk, not by a hard byte counter.
- An extension can send data to any server its host permissions or CORS allow; there is no per-extension network log.
