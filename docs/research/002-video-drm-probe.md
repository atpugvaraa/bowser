# 002 — Video / DRM capability probe (2026-10-12)

**Question:** Does a WKWebView app expose the same DRM/codec capability as Safari? What do Chrome and others get for Netflix/F1 4K on Mac?
**Method:** `spikes/media-probe/www/probe.html` run in (a) own WKWebView host (ad-hoc signed .app), (b) Safari 27.0.1, (c) Chrome 154. Uses `requestMediaKeySystemAccess` + `mediaCapabilities.decodingInfo`. Raw output: `spikes/media-probe/result-*.json`.
**Observed:**
- WKWebView == Safari on every probed item: FairPlay (`com.apple.fps`, 1_0, 2_0, 3_0) OK; HEVC 4K, HDR10, Dolby Vision, AV1 4K, VP9 4K supported; MSE/ManagedMSE, WebCodecs, PiP present.
- Chrome: all key systems `NotSupportedError` in this probe (likely probe config / Widevine on-demand load — NOT a conclusion about Chrome; no Widevine/FairPlay claim made). DV unsupported; no ManagedMSE.
**Web research (not tested by me):** Netflix lists Safari as the only Mac browser with up to 4K (macOS 11+, T2/Apple Silicon, 4K display, HDCP 2.2, Premium plan). Chrome/Firefox/Opera on Mac are capped lower (720p–1080p). Chrome 4K exists only on Windows 11 (and ChromeOS). One report claims Edge on macOS can reach 4K — UNVERIFIED. F1 TV: no reliable source found for browser resolution rules; must test.
**Confidence:** high on probe results; medium on Netflix policy (secondary sources, may be outdated).
**Unknowns:** Does Netflix serve 4K to WKWebView? It may gate by UA/browser detection/entitlement rather than capability. Does Prime Video/F1 TV 4K work? Needs logged-in test.
**Implications:** WebKit is the only realistic path to Netflix 4K on Mac; Chromium cannot beat Safari here. Next: logged-in test in own WKWebView (Safari UA vs default), Netflix stats overlay (Ctrl+Opt+Shift+D) to read the playing resolution.
Sources: netflix/techspot/daringfireball links in chat.

## Update: Netflix live test (2026-10-12, `spikes/video-test`, Standard/2-screen plan)
- WKWebView app, Safari-style UA (`applicationNameForUserAgent = "Version/17.6 Safari/605.1.15"`): Netflix decoded **1920x1080**, 0 dropped / ~2350 frames (log `~/Library/Logs/vt-video.log`). Netflix treats the app as a 1080p-capable client.
- 4K NOT verified (account lacks 4K plan). Still unknown.
- YouTube: played at 360p; my quality-forcing script was ignored; no 4K conclusion.
- Pending: same title without Safari UA, to see whether UA decides resolution.
- Result: WITHOUT Safari UA, Netflix also reached **1920x1080**, 0 dropped frames (after ramp-up from 960x540). The UA token did not change the resolution on this plan. 1080p is the plan ceiling; 4K still untested.
- YouTube 4K (user selected 2160p manually): WKWebView app decoded **3840x2160**, ~2 dropped frames in first ~500 (startup). Plays 4K fine. 
- YouTube 4K HDR (user screenshot of Stats for nerds): codec AV1 10-bit, 3840x2160@60, Color `smpte2084 (PQ) / bt2020` = HDR10 active; 3 dropped of 3015 frames. Lag observed was network-bound: connection ~12.3 Mbps, buffer health 0.00 s (sawtooth). NOT a decoder/renderer limit. Dolby Vision: capability reported by probe; YouTube does not serve DV, so untested.
