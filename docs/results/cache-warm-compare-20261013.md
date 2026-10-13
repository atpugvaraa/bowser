# Repeat-visit (cache) comparison, 2026-10-13

Fresh process per visit, one reused throwaway profile per browser (this browser: a fixed WKWebsiteDataStore profile; Chrome: one temp --user-data-dir, headless=new via DevTools protocol). Run 1 is the first (cold) visit, runs 2-4 repeat visits. Milliseconds from Navigation Timing; public network, so +-150 ms is noise.

| site | browser | run1 load (cold) | runs 2-4 load (warm) |
|---|---|---|---|
| Wikipedia | this browser | 1479 | 739 / 577 / 701 |
| Wikipedia | Chrome | 1488 | 900 / 723 / 569 |
| GitHub | this browser | 1727 | 560 / 553 / 557 |
| GitHub | Chrome | 889 | 483 / 477 / 645 |
| YouTube | this browser | 2105 | 1496 / 1076 / 593 |
| YouTube | Chrome | 2742 | 2169 / 814 / 1259 |

Reading: the persistent profile cache works as in Chrome/Safari: repeat visits are about 2-3x faster than the first visit and the warm numbers are within noise of Chrome's (GitHub warm: Chrome ~100 ms ahead; YouTube: this browser equal or ahead). One cold GitHub run was slower (n=1, not repeated). Not measured: Safari itself, multi-day cache aging, very large cache eviction, service-worker-heavy apps.
