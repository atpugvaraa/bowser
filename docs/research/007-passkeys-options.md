# 007 — Passkeys without weakening macOS security (2026-10-13)

Owner rule: SIP, AMFI, boot-args and similar are never touched. So the entitlement `com.apple.developer.web-browser.public-key-credential` cannot be faked locally; the options below are the ones left.

| Option | What you get | Fingerprint on the Mac | Apple Keychain (iCloud) passkeys | Cost / risk |
|---|---|---|---|---|
| A. Apple's entitlement | The system passkey sheet inside this browser, exactly like Safari/Chrome | yes (Touch ID) | yes | Paid Developer Program $99/yr, Account Holder files the dedicated request, Apple decides (individuals are often declined); then a Developer ID profile. Not in my hands. |
| B. Phone (hybrid) passkeys | The browser implements WebAuthn's cross-device flow: QR on the Mac, iPhone signs with the iCloud-Keychain passkey (Face ID) | no (phone biometrics) | yes | Large build (BLE advert, encrypted tunnel to the FIDO hybrid servers, CTAP2); needs Bluetooth permission; protocol is standard and also used by Chrome on Windows/Linux, but unverified for this browser. |
| C. Browser-local passkeys | The browser itself is the authenticator: Secure Enclave key per site, Touch ID per use, `navigator.credentials` handled natively with origin/rpId checks | yes | no: device-bound, not synced, not shown in the Passwords app | Medium build. Verified today: Secure Enclave keys and the biometric policy work in an unsigned and an ad-hoc signed process on this Mac (no prompt needed to create/sign with a key without user-presence flags). |
| D. Credential Exchange import | Move Apple passkeys into C | yes | copy only | macOS 26+ Passwords app export exists, but I found no confirmation that a third-party Mac app can receive it. Unverified. |

Recommendation: C first (Touch ID logins on sites that support passkeys, works today, no approval), B afterwards for Apple-Keychain passkeys, and A in parallel if you want to pay for it. Choose before I build.

## Update: Apple's own Passwords browser extension (checked 2026-10-13)
- Apple ships a native host `com.apple.passwordmanager` with manifests for Chrome (extensions `pejdij…`, `mfbcdc…`) and Firefox (`password-manager-firefox-extension@apple.com`, `apple-passwords-firefox-extension@apple.com`) under /Library.
- The helper is **killed by macOS with a Launch Constraint Violation** when started by anything other than an approved browser (verified by launching it once from a shell, nothing sent). Bypassing launch constraints would mean weakening macOS security, which is ruled out. So it cannot be used from this browser.
- It also covers passwords and verification codes only; its content script uses "webauthn" just to recognise login fields. Passkeys are not part of it.
- The extension additionally needs `chrome.webNavigation.onHistoryStateUpdated` and `chrome.privacy`, which WebKit lacks (the background script fails to load).
