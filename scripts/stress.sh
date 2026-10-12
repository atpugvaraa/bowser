#!/bin/zsh
# Engine stress/break run. Localhost only. usage: scripts/stress.sh [tabs=24] [cycles=150]
R="$(cd "$(dirname "$0")/.." && pwd)"; N=${1:-24}; C=${2:-150}
(cd "$R/app" && swift build >/tmp/_stress_build.log 2>&1) || { echo "BUILD FAILED"; grep -E "error" /tmp/_stress_build.log | head -5; exit 1; }
APP=$("$R/spikes/mkapp.sh" "$R/app" EngineStress) || exit 1
D="${TMPDIR:-/tmp}/browser-stress-$$"; mkdir -p "$D"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
(cd "$D" && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT; sleep 1
OUT="$R/docs/results/engine-stress-$(date +%Y%m%d-%H%M%S).md"
perl -e 'alarm 900; exec @ARGV' "$APP/Contents/MacOS/EngineStress" "$N" "$C" "$OUT" "$D" "http://127.0.0.1:$PORT"; rc=$?
echo "report: $OUT (exit $rc)"; exit $rc
