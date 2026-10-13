#!/bin/zsh
# Prints the frame-governor user script with a config (for the web-bench harness): fg-js.sh <maxHz> [settleMs] [idleMs]
awk '/JS-BEGIN/{f=1;next}/JS-END/{f=0}f' "$(dirname "$0")/../app/Sources/EngineWebKit/FrameGovernor.swift" | sed '1d;$d' | sed "s/__CONFIG__/{\"maxHz\":${1:-120},\"settleMs\":${2:-2000},\"idleMs\":${3:-10000},\"on\":true}/"
