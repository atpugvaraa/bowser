#!/bin/zsh
# Drives the real browser UI against local pages and prints a verdict. Temporary session, non-persistent web data. Localhost only.
R="$(cd "$(dirname "$0")/.." && pwd)"
APP=$("$R/scripts/build-app.sh") || exit 1
D="$R/app/.build/ui-selftest-pages"; mkdir -p "$D"
echo '<html><head><title>Page A</title></head><body>A</body></html>' > "$D/a.html"
echo '<html><head><title>Page B</title></head><body>B</body></html>' > "$D/b.html"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$R/scripts/testserver.py" "$PORT" "$D" >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for i in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
perl -e 'alarm 150; exec @ARGV' "$APP/Contents/MacOS/Browser" --selftest "http://127.0.0.1:$PORT"; echo "exit=$?"
