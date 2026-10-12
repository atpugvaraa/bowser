#!/bin/zsh
# usage: mkapp.sh <spike-dir> <exe-name> — wraps the SwiftPM binary in an ad-hoc signed .app
set -e; cd "$1"; A="${2}.app"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS"; cp ".build/out/Products/Debug/$2" "$A/Contents/MacOS/$2"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>$2</string><key>CFBundleIdentifier</key><string>dev.kd.$2</string><key>CFBundleName</key><string>$2</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict></dict></plist>
P
codesign -s - -f "$A" >/dev/null 2>&1; echo "$PWD/$A"
