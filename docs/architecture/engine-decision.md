# Engine decision — PROPOSED: WebKit (WKWebView), engine kept behind an interface

Status: proposed 2026-10-12, awaiting approval. Evidence: research/001, 002; spikes/profile-test.

| Requirement | Evidence | Result |
|---|---|---|
| YouTube 4K60 HDR10 (AV1) | spike: 3840x2160, 3/3015 dropped, PQ/bt2020 | PASS |
| Netflix | 1080p plan ceiling, 0 drops; 4K unverified (no plan) | PASS (4K unknown) |
| FairPlay/HEVC/DV/AV1 capability | probe == Safari | PASS |
| Per-Space profile isolation | WKWebsiteDataStore(forIdentifier:), persists | PASS |
| MV3 extensions | content script PASS; messaging needs tab registration (design item) | PARTIAL, feasible |
| Passkeys | all 3rd-party browsers hold public `web-browser.public-key-credential` entitlement | feasible, needs entitlement (Apple grant or self-sign w/ AMFI relaxed) |
| Netflix 4K on Mac | Netflix: Safari only; Chrome Mac capped | WebKit is the only path |
| DevTools | Web Inspector only (no CDP) | accepted gap |
| Chrome-only device APIs (WebUSB etc.) | absent in WebKit | accepted gap |
| Memory/battery vs Safari | engine = Safari's; shell overhead only | to measure (Phase 4) |

Reassess Chromium only if: extensions (Grammarly) cannot work AND are mandatory. Engine sits behind `BrowserEngine` protocol so a swap stays possible.
