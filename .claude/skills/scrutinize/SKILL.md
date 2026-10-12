---
name: scrutinize
description: Mandatory review gate before any commit or "done" claim in the browser project. Run after every change set; blocks on findings.
---

Before committing or declaring work done:

1. Run `scripts/gate.sh`. Fail = fix, do not bypass.
2. Review the full diff (`git diff HEAD`) skeptically, as a separate reviewer would. Use the `code-review` skill (or a fresh subagent) so the author is not the only reader.
3. Check browser-specific risks, every one explicitly:
   - TLS/cert errors never auto-bypassed; no `allowsArbitraryLoads`; no disabled App Transport Security.
   - `WKNavigationDelegate`/`WKUIDelegate` decisions: scheme allowlist (no unexpected `file:`/`javascript:` navigation), popup and permission handling.
   - JS injection / message handlers: validate origin and payload, no `evaluateJavaScript` with string-built untrusted input.
   - Retain cycles / leaks with `WKWebView`, delegates, `WKScriptMessageHandler`; web views released on tab close/hibernate.
   - Main-thread/actor correctness; no blocking I/O on main.
   - Persistence: atomic writes, migrations, survives kill -9; no credentials in plaintext/logs.
   - Hibernation never discards tabs with audio/video, downloads, or unsaved form state.
   - Extensions: permissions granted explicitly, not blanket.
4. Every behavior change has a test, or a stated reason it cannot.
5. Claims need evidence: performance/memory claims require a recorded measurement in `docs/results/`.
6. Record anything learned in `docs/LEARNINGS.md`.

Report: PASS, or a ranked findings list. Do not commit on any open High finding.
