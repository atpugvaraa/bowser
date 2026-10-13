#!/bin/zsh
# Loads REAL animation/WebGL/WASM-heavy public sites in the wb harness (one at a time) and records fps, long frames, JS errors, WebContent memory, CPU.
# Read-only browsing of public pages; no logins, no uploads. usage: scripts/realsites.sh [seconds=40]
R="$(cd "$(dirname "$0")/.." && pwd)"; S=${1:-40}; W="$R/spikes/web-bench/wb.app/Contents/MacOS/wb"
OUT="$R/docs/results/realsites-$(date +%Y%m%d-%H%M%S).txt"; : > "$OUT"
SITES=(
 "https://threejs.org/examples/webgl_morphtargets_horse.html"
 "https://threejs.org/examples/webgl_instancing_performance.html"
 "https://threejs.org/examples/webgpu_compute_particles.html"
 "https://webglsamples.org/aquarium/aquarium.html"
 "https://webglsamples.org/dynamic-cubemap/dynamic-cubemap.html"
 "https://editor.godotengine.org/releases/latest/"
 "https://www.shadertoy.com/view/Xds3zN"
 "https://playcanvas.com/project/406049/overview/fly-through-a-castle"
 "https://www.apple.com/macbook-pro/"
 "https://stripe.com/"
 "https://www.nytimes.com/"
 "https://www.youtube.com/"
)
for u in $SITES; do echo "## $u" | tee -a "$OUT"; perl -e 'alarm 120; exec @ARGV' "$W" "$u" $S --safari-ua 2>&1 | grep RESULT | cut -c1-600 | tee -a "$OUT"; done
echo "wrote $OUT"
