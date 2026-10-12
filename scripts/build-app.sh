#!/bin/zsh
# Build the browser as a real .app bundle (ad-hoc signed; full Xcode signing/entitlements come later). usage: scripts/build-app.sh
R="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$R/app" && swift build >"$R/app/.build/app-build.log" 2>&1) || { echo "BUILD FAILED"; grep -E "error" "$R/app/.build/app-build.log" | head -5; exit 1; }
A="$R/app/.build/BrowserApp/Browser.app"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$R/app/.build/out/Products/Debug/BrowserApp" "$A/Contents/MacOS/Browser"
cat > "$A/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Browser</string><key>CFBundleIdentifier</key><string>dev.kd.browser</string><key>CFBundleName</key><string>Browser</string>
<key>CFBundleDisplayName</key><string>Browser</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.4</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
codesign -s - -f "$A" >/dev/null 2>&1; echo "$A"
