#!/bin/zsh
# Engine stress/break run. Localhost only. usage: scripts/stress.sh [tabs=24] [cycles=150]
R="$(cd "$(dirname "$0")/.." && pwd)"; N=${1:-24}; C=${2:-150}
(cd "$R/app" && swift build >$R/app/.build/stress-build.log 2>&1) || { echo "BUILD FAILED"; grep -E "error" $R/app/.build/stress-build.log | head -5; exit 1; }
APP=$("$R/spikes/mkapp.sh" "$R/app" EngineStress) || exit 1
D="$R/app/.build/stress-data"; mkdir -p "$D"   # fixed, git-ignored; files are overwritten, never deleted
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$R/scripts/testserver.py" "$PORT" "$D" >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for i in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "test server did not start"; exit 1; }
OUT="$R/docs/results/engine-stress-$(date +%Y%m%d-%H%M%S).md"
perl -e 'alarm 900; exec @ARGV' "$APP/Contents/MacOS/EngineStress" "$N" "$C" "$OUT" "$D" "http://127.0.0.1:$PORT"; rc=$?
echo "report: $OUT (exit $rc)"; exit $rc
