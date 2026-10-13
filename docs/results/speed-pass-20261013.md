# Speed pass (2026-10-13)

Changes (EngineWebKit/SpeedTuning.swift, WebKitTabFactory, BrowserWindowController): (1) persistent profile stores get Safari-style **speculative cache revalidation** (WebKit leaves it off for embedders); (2) the address bar **preconnects** (DNS+TCP+TLS) to the page being typed once typing pauses 0.4 s and the text looks like a complete https host;  Verified: tuned store shares cookies/logins with the standard store in both directions (separate processes).

## Warm repeat visits, speculative revalidation off vs on (median of visits 2-4, persistent profile, ms)
| site | load off | load on |
|---|---|---|
| bbc.com/news | 2452 | 404 |
| youtube.com | 2048 | 1483 |
| wikipedia (Safari article) | 646 | 554 |
| github.com | 497 | 567 (inside noise) |

## Preconnect 600 ms before navigation, cold (median of 5, ms)
| site | TTFB off -> on | load off -> on |
|---|---|---|
| github.com | 220 -> 121 | 1691 -> 992 |
| bbc.com/news | 221 -> 42 | 3851 -> 2319 |
| nytimes.com | 525 -> 417 | 1857 -> 2138 (worse, noise-level) |
| reddit.com | 327 -> 322 | 5567 -> 4989 |

Caveats: n=3-5 per cell on a public network; first-visit loads are unchanged by the cache setting; preconnect only helps when the user types ahead. Not measured: effect on memory/battery (idle sockets are held for seconds), Safari itself.
Privacy: preconnect only fires for a complete-looking https host the user typed (no partial names); nothing is prefetched speculatively.

Dropped: warming the first web process via WKProcessPool. Apple deprecated process pools (no effect since macOS 12) and WebKit starts a spare web process on its own, so there is nothing to gain.
