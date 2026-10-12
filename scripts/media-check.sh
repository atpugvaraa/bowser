#!/bin/zsh
# Media regression guard: a WKWebView app must keep FairPlay + 4K HEVC/HDR10/AV1 capability (Netflix/YouTube/Prime).
# Capability-level only (not a playback test). Localhost server on a free port; unique nonce so stale results can't pass.
# SKIP_MEDIA=1 skips (exit 3 so the gate can warn loudly).
[ -n "$SKIP_MEDIA" ] && { echo "WARN: media check SKIPPED"; exit 3; }
R="$(cd "$(dirname "$0")/.." && pwd)"; P="$R/spikes/media-probe"
cd "$P" || exit 1
swift build >/tmp/_mc_build.log 2>&1 || { echo "MEDIA FAIL: probe build failed"; tail -5 /tmp/_mc_build.log; exit 1; }
APP=$("$R/spikes/mkapp.sh" "$P" probe) || { echo "MEDIA FAIL: app bundle"; exit 1; }
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
NONCE="n$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
rm -f -- "result-$NONCE.json"
python3 server.py "$PORT" >/dev/null 2>&1 & SRV=$!
"$APP/Contents/MacOS/probe" "http://127.0.0.1:$PORT/probe.html#$NONCE" >/dev/null 2>&1 & PRB=$!
trap 'kill $SRV $PRB 2>/dev/null; pkill -f "$APP/Contents/MacOS/probe" 2>/dev/null; rm -f "result-$NONCE.json"' EXIT
for i in $(seq 1 40); do [ -f "result-$NONCE.json" ] && break; sleep 1; done
[ -f "result-$NONCE.json" ] || { echo "MEDIA FAIL: probe produced no result (did not run / timed out)"; exit 1; }
python3 -I - "result-$NONCE.json" "$NONCE" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); bad=[]
if r.get("nonce")!=sys.argv[2]: bad.append("nonce mismatch")
if not r["eme"].get("com.apple.fps","").startswith("OK"): bad.append("FairPlay")
for k in ("hevc4k","hevc4k_hdr10","av1_4k","vp9_4k","h264_1080"):
    if "sup=true" not in r["mc"].get(k,""): bad.append(k)
if not r["misc"].get("pip"): bad.append("PiP")
if bad: print("MEDIA FAIL:", bad); sys.exit(1)
print("MEDIA OK: FairPlay, HEVC4K, HDR10, AV1 4K, VP9 4K, H264, PiP (capability check)")
PY
