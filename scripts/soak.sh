#!/bin/zsh
# LONG SOAK: 500 tabs (default) under the adaptive hibernation policy for N hours, sampling the whole machine every minute.
# Localhost only. Safe to leave running; it refuses to start if the Mac is already under memory pressure / heavy swap, and the
# engine's own memory guard aborts the run if pressure goes critical. Nothing is deleted (reports are timestamped new files).
#   scripts/soak.sh [hours=8] [tabs=500] [liveBudget=100]
#   scripts/soak.sh --safari [hours=8] [tabs=500]     # BASELINE: same pages in Safari (only browser running), same sampling
# Output: docs/results/soak-<timestamp>.csv (minute samples) + engine-scale-*.md (the engine report) / soak-safari-*.csv.
R="$(cd "$(dirname "$0")/.." && pwd)"; TS=$(date +%Y%m%d-%H%M%S)
sample() {   # writes one CSV row: time, swap_used_MB, pressure, webcontent_MB, gpu_proc_MB, networking_MB, app_MB
  local swap pres wc gpu net app
  swap=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')
  pres=$(memory_pressure -Q 2>/dev/null | grep -o 'System-wide memory free percentage: [0-9]*' | grep -o '[0-9]*$')
  mb() { ps -axo rss=,command= | grep -E "$1" | grep -v grep | awk '{s+=$1} END {printf "%d", s/1024}'; }
  wc=$(mb 'com.apple.WebKit.WebContent'); gpu=$(mb 'com.apple.WebKit.GPU'); net=$(mb 'com.apple.WebKit.Networking'); app=$(mb "$1")
  echo "$(date +%H:%M:%S),$swap,${pres:-NA},$wc,$gpu,$net,$app"
}
if [[ "$1" == "--safari" ]]; then
  H=${2:-8}; N=${3:-500}; CSV="$R/docs/results/soak-safari-$TS.csv"
  pgrep -x "Google Chrome" >/dev/null && { echo "close Chrome first (baseline must be the only browser)"; exit 1; }
  D="$R/app/.build/scale-data"; mkdir -p "$D"
  for i in $(seq 0 $((N - 1))); do echo "<title>t$i</title><body style='font:16px sans-serif'><h1>Tab $i</h1><canvas id=c width=300 height=200></canvas><script>var x=document.getElementById('c').getContext('2d');setInterval(function(){x.fillStyle='hsl('+(Math.random()*360)+',60%,50%)';x.fillRect(Math.random()*300,Math.random()*200,20,20)},500);var a=[];for(var i=0;i<300000;i++)a.push({i:i,s:'v'+i});</script>" > "$D/sk$i.html"; done
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  python3 "$R/scripts/testserver.py" "$PORT" "$D" >/dev/null 2>&1 & SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT; sleep 1
  echo "time,swap_used_MB,mem_free_pct,webcontent_MB,gpu_MB,networking_MB,safari_MB" > "$CSV"
  echo "opening $N tabs in Safari in batches of 25 (watch memory; Ctrl-C stops)…"
  for b in $(seq 0 25 $((N - 1))); do
    urls=(); for i in $(seq $b $((b + 24 < N ? b + 24 : N - 1))); do urls+=("http://127.0.0.1:$PORT/sk$i.html"); done
    open -a Safari "${urls[@]}"; sleep 20; sample "Safari.app" >> "$CSV"
    swap=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/'); [[ ${swap%.*} -gt 9000 ]] && { echo "swap > 9 GB: stopping opening tabs (Safari baseline reached the machine's limit at $((b + 25)) tabs)"; break; }
  done
  END=$(( $(date +%s) + H * 3600 )); while [[ $(date +%s) -lt $END ]]; do sample "Safari.app" >> "$CSV"; sleep 60; done
  echo "done: $CSV"; exit 0
fi
H=${1:-8}; N=${2:-500}; L=${3:-100}; CSV="$R/docs/results/soak-$TS.csv"
echo "time,swap_used_MB,mem_free_pct,webcontent_MB,gpu_MB,networking_MB,engine_MB" > "$CSV"
( while true; do sample "EngineScale" >> "$CSV"; sleep 60; done ) & SAMP=$!; trap 'kill $SAMP 2>/dev/null' EXIT
"$R/scripts/scale.sh" "$N" "$L" 300 $((H * 3600))
echo "samples: $CSV   (compare against: scripts/soak.sh --safari $H $N)"
