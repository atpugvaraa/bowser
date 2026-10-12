#!/bin/zsh
# Scale/soak run. Localhost only. usage: scripts/scale.sh [tabs=500] [live=100] [activations=300] [soakSeconds=0]
R="$(cd "$(dirname "$0")/.." && pwd)"; N=${1:-500}; L=${2:-100}; A=${3:-300}; S=${4:-0}
(cd "$R/app" && swift build >$R/app/.build/scale-build.log 2>&1) || { echo "BUILD FAILED"; grep -E "error" $R/app/.build/scale-build.log | head -5; exit 1; }
APP=$("$R/spikes/mkapp.sh" "$R/app" EngineScale) || exit 1
D="$R/app/.build/scale-data"; mkdir -p "$D"   # fixed, git-ignored; files are overwritten, never deleted
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$R/scripts/testserver.py" "$PORT" "$D" >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for i in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "test server did not start"; exit 1; }
OUT="$R/docs/results/engine-scale-$(date +%Y%m%d-%H%M%S).md"
perl -e 'alarm('"$((S + 1500))"'); exec @ARGV' "$APP/Contents/MacOS/EngineScale" "$N" "$L" "$A" "$S" "$OUT" "$D" "http://127.0.0.1:$PORT"; rc=$?
echo "report: $OUT (exit $rc)"; exit $rc
