# 003 — Engine features, hibernation memory, and stress results (2026-10-12/13)

## Question 1: can we strip unneeded features out of the engine to make it more efficient?
**Method:** enumerate WebKit's runtime feature flags via private `WKPreferences._features` (read-only); toggle candidates through `_setEnabled:forFeature:`; measure total WebContent footprint (`proc_pid_rusage` phys_footprint) over an identical 8-view × 5-navigation session (spikes/webkit-features `wf2`). Raw list: `webkit-features-macos27.tsv` (966 rows across 3 sets, ~500 enabled by default).
**Observed:** default 329 MB. `UsesBackForwardCache=off` alone 314 MB (-4.6%); full "lean" bundle (WebGPU, SpeechRecognition, SpeechSynthesis, Gamepads, VisualTranslation, TextRecognitionInVideos, ModelElement + no bfcache) also 314 MB. Back navigation 10 ms both ways. 3 repeats, identical.
**Conclusion:** unused features cost ~nothing at idle; only the page cache matters (~5%). **Patching/rebuilding the system WebKit is not worth it and not viable**: WebKit is a SIP-protected system framework in the dyld shared cache; a custom build would not be Apple-signed so FairPlay (Netflix/protected video) would be lost, and it would drop Apple security updates. The real levers are hibernation, process management, content blocking and policy.
**Confidence:** high for this workload (synthetic pages); features may matter for sites that actually use them (WebGL/WebGPU/WebRTC pages). **Unknown:** CPU/GPU cost of TextRecognitionInVideos while playing real video.

## Question 2: how much memory does real hibernation reclaim, and is it safe?
**Method:** `EngineStress` (app/Sources/EngineStress, scripts/stress.sh): real WKWebViews + WebContent processes, localhost pages (8 MB JS heap + 2000 DOM nodes each), hibernate = capture `interactionState`, destroy the web view; resume = recreate + restore; policy consulted for protections.
**Observed (24 tabs, 200 churn cycles, macOS 27.0.1):** all live 1190 MB WebContent -> 213 MB with 20 hibernated (**82% reclaimed**); 24/24 restored with correct URL in 0.5 s; host memory flat 40->40 MB over 200 cycles; 0 leaked web views; 33 hibernations of protected (dirty-form) tab refused; SIGKILL of a WebContent process: crash callback fired, tab recovered. Earlier runs 12-16 tabs: 64-73%.
**Bugs found by the harness (all mine, fixed):** dirty-form script never installed in the configuration; restore check ran before restore began; crash test looked for a pid before processes started; script ran a stale binary after a failed build; churn ignored policy protections.
**Open:** an intermittent web-view retention (1 view alive >15 s, always tab 0 of the harness) did not reproduce in isolated WebKit experiments (spikes/leak-hunt, 0/30); treated as a harness-path issue, tracked, memory reclaim is the hard criterion.
**Design finding:** a WebContent crash or hibernation loses unsaved form input; policy protects dirty tabs, but a crash cannot be protected => backlog: draft-saver (debounced input snapshot + restore).

## Question 3: is the session store crash-safe?
**Method:** CoreChecks section 13: a child process saves 400-tab states in a loop, parent SIGKILLs it at varied moments x14, reopens and loads. Plus abandoned-transaction, migration v1->v2, corrupt/newer files, 5-seed fuzz (3000 ops each) with tab conservation and save/load round trips.
**Observed:** 14/14 reopen valid (WAL present every time). Fuzz found a real bug: titles with NUL bytes were truncated (fixed: length-aware bind/read).
