#!/bin/zsh
# Build the browser as a real .app bundle. Signs with the first "Apple Development"/"Developer ID Application" identity in the keychain
# (hardened runtime + camera/mic entitlements), else ad-hoc. Passkey entitlement: put Apple's approved profile at scripts/signing/embedded.provisionprofile
# and the build uses scripts/signing/Browser-passkeys.entitlements. usage: scripts/build-app.sh [--release]
R="$(cd "$(dirname "$0")/.." && pwd)"
CFG=Debug; FLAGS=(); [[ "$1" == "--release" ]] && { CFG=Release; FLAGS=(-c release --product BrowserApp); }
(cd "$R/app" && swift build "${FLAGS[@]}" >"$R/app/.build/app-build.log" 2>&1) || { echo "BUILD FAILED"; grep -E "error" "$R/app/.build/app-build.log" | head -5; exit 1; }
BUILDID="$(git -C "$R" rev-parse --short HEAD 2>/dev/null)-$(date +%m%d-%H%M)"
A="$R/app/.build/BrowserApp/Browser.app"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp "$R/app/.build/out/Products/$CFG/BrowserApp" "$A/Contents/MacOS/Browser"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Browser</string><key>CFBundleIdentifier</key><string>dev.kd.browser</string><key>CFBundleName</key><string>Browser</string>
<key>CFBundleDisplayName</key><string>Browser</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.1 ($BUILDID)</string>
<key>LSMinimumSystemVersion</key><string>15.4</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Used only while signing in with a passkey on your phone: it listens for your phone's nearby sign-in request.</string>
<key>NSCameraUsageDescription</key><string>Websites you allow can use the camera (video calls).</string><key>NSMicrophoneUsageDescription</key><string>Websites you allow can use the microphone (calls, voice input).</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Apple Development|Developer ID Application)' | head -1 | sed -E 's/.*"(.*)".*/\1/')
PROF="$R/scripts/signing/embedded.provisionprofile"; ENT="$R/scripts/signing/Browser.entitlements"
[[ -f "$PROF" ]] && { cp "$PROF" "$A/Contents/embedded.provisionprofile"; ENT="$R/scripts/signing/Browser-passkeys.entitlements"; }
if [[ -n "$ID" ]]; then
  codesign --force --options runtime --entitlements "$ENT" -s "$ID" "$A" >&2 && echo "signed as: $ID" >&2
else
  codesign --force --options runtime --entitlements "$ENT" -s - "$A" >/dev/null 2>&1; echo "ad-hoc signed (hardened runtime + camera/mic entitlements; macOS will re-ask permission after every rebuild) ; no identity in the keychain: see docs/SIGNING.md)" >&2
fi
codesign -dv "$A" 2>&1 | grep -E "Identifier|flags|Authority" >&2
if [[ "$CFG" == "Release" ]]; then   # a fresh copy each time: overwriting a binary macOS has already run makes the kernel kill it (and nothing is ever deleted)
  D="$R/dist/Browser-$(date +%m%d-%H%M%S).app"; mkdir -p "$R/dist" && cp -R "$A" "$D" && echo "release copy: $D" >&2 && echo "$D" && exit 0
fi
echo "$A"
