#!/bin/zsh
# Runs the real UI under malloc stack logging with a long open/close cycle test, then asks Apple's `leaks` to inspect the LIVE process.
# Localhost only. usage: scripts/leaks-check.sh [cycles=150]
R="$(cd "$(dirname "$0")/.." && pwd)"; C=${1:-150}
APP=$("$R/scripts/build-app.sh") || exit 1
D="$R/app/.build/ui-selftest-pages"; mkdir -p "$D"
echo '<html><head><title>Page A</title></head><body>A</body></html>' > "$D/a.html"; echo '<html><head><title>Page B</title></head><body>B</body></html>' > "$D/b.html"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$R/scripts/testserver.py" "$PORT" "$D" >/dev/null 2>&1 & SRV=$!
for i in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
OUT="$R/app/.build/leaks-run.out"; : > "$OUT"
MallocStackLogging=1 SELFTEST_HOLD=1 SELFTEST_CYCLES=$C "$APP/Contents/MacOS/Browser" --selftest "http://127.0.0.1:$PORT" > "$OUT" 2>&1 & APID=$!
trap 'kill $SRV $APID 2>/dev/null' EXIT
for i in $(seq 1 600); do grep -q "HOLDING" "$OUT" && break; kill -0 $APID 2>/dev/null || break; sleep 1; done
grep -E '^(FAIL|SELFTEST|     \(host)' "$OUT"
grep -q "HOLDING" "$OUT" || { echo "app did not reach the hold point"; tail -5 "$OUT"; exit 1; }
echo "--- leaks (live process, host app) ---"
LF="$R/app/.build/leaks-full.txt"; leaks $APID > "$LF" 2>&1
grep -E 'Process [0-9]+: [0-9]+ leak' "$LF" | head -1
echo "leak roots by type:"; grep -E 'ROOT (LEAK|CYCLE)' "$LF" | sed -E 's/0x[0-9a-f]+//g; s/\[[0-9]+\]//; s/^ +//; s/^[0-9]+ \([^)]*\) //' | cut -c1-100 | sort | uniq -c | sort -rn | head -12
echo "leaks mentioning our own code: $(grep -c -E 'BrowserCore|EngineCore|EngineWebKit|BrowserApp|Persistence|Lifecycle|ContentBlocking' "$LF")"
echo "--- vmmap summary ---"; vmmap -summary $APID 2>/dev/null | grep -E 'Physical footprint|^TOTAL|MALLOC' | head -6
