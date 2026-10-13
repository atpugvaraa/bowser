# Signing the browser (what only you can do, then what runs by itself)

Looked up 2026-10-13 against Apple's developer forums and docs. I cannot do steps 1 and 4: they need your Apple ID and, for passkeys, Apple's approval.

## 1. One-time: get a signing certificate (free, ~5 min, needs you at the keyboard)
1. Open **Xcode ▸ Settings ▸ Apple Accounts ▸ +** and sign in with your Apple ID (a free account is enough).
2. Select your account, click **Manage Certificates… ▸ + ▸ Apple Development**. (Apple has no command-line way to create the free "Personal Team" certificate; this step is Xcode-only.)
3. Check it landed: `security find-identity -v -p codesigning` should now list `Apple Development: …`.

## 2. Build a signed app (automatic from here)
`scripts/build-app.sh` finds that identity and signs with the hardened runtime and the camera/microphone entitlements (`scripts/signing/Browser.entitlements`). It prints `signed as: …`. Verify: `codesign -dv --entitlements - app/.build/BrowserApp/Browser.app`.
Effects: macOS keychain/permission prompts stop repeating after each rebuild, and camera/mic (calls, meetings) switch on, behind the browser's own "Allow this site?" prompt.
Even without step 1 the script now builds with hardened runtime and those entitlements ad-hoc; macOS just re-asks permission after every rebuild.

## 3. Passwords (no Apple approval needed, to be tested once signed)
- **System AutoFill / Passwords app**: test a signed build on a real login page. Reported unreliable in third-party WKWebView browsers; I will record what happens.
- **iCloud Passwords extension**: Apple documents it for Chromium browsers; the extension talks to Apple's helper through native messaging, which WebKit's extension engine does not provide. I have not found a supported way to reach the helper from this browser and will not poke at other apps' data to find one.

## 4. Passkeys (needs Apple's approval; not guaranteed)
Passkeys in a third-party browser need the restricted entitlement `com.apple.developer.web-browser.public-key-credential`.
1. Join the **paid Apple Developer Program** ($99/yr). A free account cannot hold this entitlement.
2. The **Account Holder** (the person who enrolled) submits the dedicated request form linked from Apple's page for the entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential . Other roles cannot open the form (Apple DTS, forum thread 829169). It is a different form from the general entitlement request.
3. Apple reviews it. Individual accounts are reported to be declined often; Chrome, Arc and a few others have it. Nothing I can do speeds this up.
4. After approval: in the developer portal create an App ID for `dev.kd.browser` with that capability, make a **Developer ID** provisioning profile, download it, save it as `scripts/signing/embedded.provisionprofile`, and sign with a **Developer ID Application** certificate. `build-app.sh` then switches to `scripts/signing/Browser-passkeys.entitlements` by itself.
5. Even with the entitlement, one Chromium-browser developer reports it working only partly (repeated password prompts, an error creating a Google passkey), so test before relying on it.

## Weakening macOS security
Ruled out by the owner (2026-10-13): SIP, AMFI, boot-args and similar are never changed for this project. Passkey options that keep security intact are in docs/research/007-passkeys-options.md.
