#!/bin/zsh
# POWER + GPU DRAW comparison: this browser's WebKit host vs Safari vs Chrome on the same workloads.
# Needs sudo (powermetrics). Run on battery or plugged in (it records which), lid open, display on, other apps closed.
#   sudo scripts/power-gpu.sh [measureSeconds=60]
# Workloads: idle (about:blank), aquarium-30k (WebGL, local proxy of the public page), threejs-horse (public, WebGL).
# Output: docs/results/power-<timestamp>.md  (average CPU / GPU / combined mW per browser x workload) + raw samples next to it.
# Safe: read-only browsing of public pages; localhost proxy; nothing is deleted. Safari/Chrome tabs opened by this script stay
# open: close them yourself afterwards.
[[ $EUID -eq 0 ]] || { echo "run with sudo (powermetrics needs root): sudo $0 $*"; exit 1; }
R="$(cd "$(dirname "$0")/.." && pwd)"; M=${1:-60}; SETTLE=20
WB="$R/spikes/web-bench/wb.app/Contents/MacOS/wb"
[[ -x "$WB" ]] || { echo "build the harness first: (cd $R/spikes/web-bench && swift build && ../mkapp.sh . wb)"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S); OUT="$R/docs/results/power-$TS.md"; RAW="$R/docs/results/power-$TS-raw"; mkdir -p "$RAW"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
WWW="$R/spikes/web-bench/www"; GP=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
(cd "$R/spikes/web-bench" && python3 aqproxy.py "$PORT" >/dev/null 2>&1) & PROXY=$!
(cd "$WWW" && python3 "$R/scripts/testserver.py" "$GP" "$WWW" >/dev/null 2>&1) & GLSRV=$!
trap 'kill $PROXY $GLSRV 2>/dev/null' EXIT; sleep 1
typeset -A URL; URL=(idle "about:blank" aquarium-30k "http://127.0.0.1:$PORT/aquarium/aquarium.html" webgl-shader "http://127.0.0.1:$GP/power-gl.html")
BATT=$(pmset -g batt | head -2 | tr '\n' ' ')
echo "# Power / GPU comparison $TS\n\nPower source: $BATT\nMeasure window: ${M}s after ${SETTLE}s settle. Mac: $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productVersion)\n\n| workload | browser | CPU mW | GPU mW | Combined mW | GPU busy % | page fps (own beacon) | valid? |\n|---|---|---|---|---|---|---|---|" > "$OUT"
measure() {   # $1 workload  $2 browser
  local f="$RAW/$1-$2.txt"
  powermetrics --samplers cpu_power,gpu_power -i 1000 -n "$M" > "$f" 2>&1
  local fps="n/a"; if [[ $1 == webgl-shader ]]; then fps=$(python3 -c "import json;print(json.load(open('$WWW/result-pw.json'))['fps'])" 2>/dev/null || echo n/a)
  elif [[ $1 == aquarium-30k ]]; then fps=$(python3 -c "import json;print(json.load(open('$R/spikes/web-bench/aq-result.json'))['median_fps'])" 2>/dev/null || echo n/a); fi
  python3 - "$f" "$1" "$2" "$fps" >> "$OUT" <<'PY'
import re,sys,statistics as st
t=open(sys.argv[1]).read()
def vals(p): return [float(x) for x in re.findall(p,t)]
cpu=vals(r'CPU Power: (\d+) mW'); gpu=vals(r'GPU Power: (\d+) mW'); comb=vals(r'Combined Power \(CPU \+ GPU \+ ANE\): (\d+) mW'); busy=vals(r'GPU HW active residency:\s+([\d.]+)%')
f=lambda v: f"{st.mean(v):.0f}" if v else "n/a"
fps=sys.argv[4]; ok = "yes" if sys.argv[2]=="idle" else ("yes" if fps.replace(".","").isdigit() and float(fps)>=20 else "NO: page not rendering / no beacon")
print(f"| {sys.argv[2]} | {sys.argv[3]} | {f(cpu)} | {f(gpu)} | {f(comb)} | {f(busy)} | {fps} | {ok} |")
PY
}
for w in idle aquarium-30k webgl-shader; do
  u=${URL[$w]}; [[ $w == webgl-shader ]] && u="$u#pw"; : > "$WWW/result-pw.json"; : > "$R/spikes/web-bench/aq-result.json"
  echo "== $w: this browser's WebKit host"; "$WB" "$u" $((SETTLE + M + 10)) --safari-ua >/dev/null 2>&1 & WP=$!
  sleep $SETTLE; measure $w "this-browser(WebKit)"; wait $WP 2>/dev/null
  if [[ $w != idle ]]; then
    for b in Safari "Google Chrome"; do
      echo "== $w: $b"; sudo -u "$SUDO_USER" open -a "$b" "$u"; sudo -u "$SUDO_USER" osascript -e "tell application \"$b\" to activate" >/dev/null 2>&1; sleep $SETTLE; measure $w "$b"
      sudo -u "$SUDO_USER" osascript -e "tell application \"$b\" to close front window" >/dev/null 2>&1   # close the window we opened (a tab, not a file)
      sleep 5
    done
  fi
done
echo "\nRaw powermetrics samples: docs/results/power-$TS-raw/. Lower mW = longer battery. Compare browsers within a workload only. Rows marked NO were not rendering and must be ignored. Do other work on the Mac during the run: don't (it skews every number)." >> "$OUT"
echo "done: $OUT"; cat "$OUT"
