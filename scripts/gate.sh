#!/bin/zsh
# Commit gate: build (warnings = errors), tests, secret scan. Run from repo root.
set -e
cd "$(dirname "$0")/.."
bad=$(git diff --cached -U0 2>/dev/null | grep -E '^\+' | grep -iE '(api[_-]?key|secret|password|token)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9/+_-]{16,}|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY' || true)
[ -z "$bad" ] || { echo "GATE FAIL: possible secret in staged diff:\n$bad"; exit 1; }
for p in app/Package.swift; do
  [ -f "$p" ] || continue
  d=$(dirname "$p")
  (cd "$d" && swift build -Xswiftc -warnings-as-errors && swift test)
done
echo "GATE OK"
