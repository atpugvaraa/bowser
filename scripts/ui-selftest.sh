#!/bin/zsh
# Drives the real browser UI against local pages (127.0.0.1 only; first tab is about:blank, nothing leaves the machine).
# Temporary session + non-persistent web data. Exit status is the verdict: 0 only on an explicit SELFTEST PASS.
R="$(cd "$(dirname "$0")/.." && pwd)"
APP=$("$R/scripts/build-app.sh") || exit 1
D="$R/app/.build/ui-selftest-pages"; mkdir -p "$D"
echo '<html><head><title>Page A</title></head><body>A</body></html>' > "$D/a.html"
echo '<html><head><title>Page B</title></head><body>B</body></html>' > "$D/b.html"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$R/scripts/testserver.py" "$PORT" "$D" >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for i in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
out=$(perl -e 'alarm 150; exec @ARGV' "$APP/Contents/MacOS/Browser" --selftest "http://127.0.0.1:$PORT" 2>&1); rc=$?
print -r -- "$out"
if [ $rc -eq 0 ] && print -r -- "$out" | grep -q "^SELFTEST PASS$"; then exit 0; fi
echo "UI self-test did not pass (exit $rc: ${rc/142/timeout}); a crash or timeout counts as failure"; exit 1
