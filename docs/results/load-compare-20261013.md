# Page load comparison (2026-10-13), cold, throwaway profiles, this Mac, public network

Method: fresh process per run, nonpersistent data store (Chrome: fresh temp profile, headless=new, DevTools protocol), runs alternated, medians of runs that finished. Metrics from Navigation Timing / paint timing in ms. Network noise is large (Chrome's own runs ranged 1.8–5.9 s load); read differences under ~15% as noise.

## YouTube home page
| setup | n | first contentful paint | DOMContentLoaded | load |
|---|---|---|---|---|
| Chrome (cold, headless) | 6 | 1210 | 2498 | 3522 |
| Bare WebKit view, Safari identity | 5 | 1664 | 1791 | 2315 |
| This browser's configuration | 6 | 1537 | 1448 | 1917 |
| Bare view + prefetch/preload flags | 5 | 1374 | 1491 | 1990 |
| (old, no Safari token) Bare view, legacy page | 6 | 470 | 1117 | 1478 |

## Local page (no network), 15 loads in one process
Bare view 16 ms load; this browser's configuration 13 ms. Scripts for frame rate, passkeys and extensions add no measurable cost.

## Reading it
- The engine is not slower than Chrome in a like-for-like cold run, and the injected scripts are not the cause of any slowdown.
- The big change was the identity: with a Safari identity YouTube serves its full modern page (first paint 470 -> ~1500 ms) instead of the legacy page. That is the same page Safari gets.
- Enabling LinkPrefetch / SpeculationRules prefetch / MediaPreloading gave ~10% (inside noise) and adds speculative network traffic, so it was NOT enabled.
- Not measured: warm-cache loads in a persistent profile (where Chrome's long-running warm processes help), video start time, scrolling smoothness.
