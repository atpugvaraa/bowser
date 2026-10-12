#!/bin/zsh
# Commit gate: secret scan, core build (warnings = errors), self-checking tests, media regression guard.
cd "$(dirname "$0")/.." || exit 1
bad=$(git diff --cached -U0 2>/dev/null | grep -E '^\+' | grep -iE '(api[_-]?key|secret|passw(or)?d|token)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9/+_-]{16,}|BEGIN (RSA|EC|OPENSSH|PRIVATE) .*KEY|Bearer [A-Za-z0-9._-]{16,}|gho_[A-Za-z0-9]{20,}' || true)
[ -z "$bad" ] || { print -r -- "GATE FAIL: possible secret in staged diff:"; print -r -- "$bad"; exit 1; }
if [ -f app/Package.swift ]; then
  (cd app && swift build -Xswiftc -warnings-as-errors >/tmp/_gate_build.log 2>&1) || { echo "GATE FAIL: core build"; grep -E 'error' /tmp/_gate_build.log | head -5; exit 1; }
  out=$(cd app && perl -e "alarm 240; exec @ARGV" swift run --skip-build CoreChecks 2>&1); rc=$?
  print -r -- "$out" | grep -E '^(FAIL|ALL|[0-9]+ CHECK)'
  [ $rc -eq 0 ] && print -r -- "$out" | grep -q '^ALL CHECKS PASSED$' && ! print -r -- "$out" | grep -q '^FAIL' || { echo "GATE FAIL: core checks (rc=$rc)"; exit 1; }
fi
scripts/media-check.sh; mrc=$?
[ $mrc -eq 0 ] || [ $mrc -eq 3 ] || { echo "GATE FAIL: media regression (video/Netflix capability)"; exit 1; }
[ $mrc -eq 3 ] && { echo "GATE OK (WITH MEDIA CHECK SKIPPED)"; exit 0; }
echo "GATE OK"
