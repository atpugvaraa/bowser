# 008 — Phone (QR / hybrid) passkeys: plan (2026-10-13)

Goal: sign in with passkeys that live in the iPhone's iCloud Keychain, from this browser, with no change to macOS security. The Mac shows a QR code, the iPhone scans it, the user approves on the phone (Face ID), the browser receives a normal WebAuthn assertion.

Protocol facts, read from FIDO CTAP 2.2 §11.5 (fidoalliance.org/specs/fido-v2.2-ps-20250714): this browser is the **client platform**.

1. **QR**: `FIDO:/` + decimal digits of a CBOR map {0: our 33-byte compressed P-256 public key, 1: 16-byte random secret, 2: number of assigned tunnel domains we know (2), 3: unix time, 5: "ga" or "mc"}. Digits: 7-byte little-endian chunks, 17 digits each (remainder 3/5/8/10/13/15 digits).
2. **HKDF-SHA256** from the 16-byte secret, info = 4-byte LE purpose: 1 = EID key (64 bytes: AES-256 key + HMAC key), 2 = tunnel id (16 bytes), 3 = PSK (32 bytes, salt = the decrypted advert).
3. **BLE**: scan for service data UUID `0000fff9-0000-1000-8000-00805f9b34fb`, 20 bytes = 16-byte AES-256 single-block (ECB) ciphertext + 4-byte HMAC-SHA256 tag (constant-time compare). Plaintext: flags(0), 10-byte nonce, 3-byte routing id, 2-byte LE tunnel-domain id. BLE is only a proximity proof, no data.
4. **Tunnel**: `wss://<domain>/cable/connect/<routing hex>/<tunnel-id hex>`, subprotocol `fido.cable`, follow redirects. Domain 0 = cable.ua5v.com, 1 = cable.auth.com, ≥256 hashed (SHA-256 of "caBLEv2 tunnel server domain" + id LE16 + 0; base32 of the digest >> 2, TLD from the low 2 bits). We connect first.
5. **Noise KNpsk0** (P-256, SHA-256, AES-256-GCM): we are the initiator, our QR key is the static key, PSK from step 2. First message = ephemeral point + encrypted empty payload; after the handshake: separate send/receive AES-GCM keys, 32-bit big-endian counters in a 12-byte nonce, empty AAD, plaintext padded to a multiple of 32 (last byte = pad count).
6. **Messages**: first message from the phone is CBOR {1: getInfo response, 3: features}. We send type 1 + CTAP request (getAssertion `0x02` / makeCredential `0x01` CBOR with clientDataHash), receive status byte + CBOR, then send type 0 (shutdown). Type 2 (linking updates) is ignored (no state-assisted mode).

## Build steps (each ends with tests; nothing is pushed)
1. `Hybrid` module: CBOR encode/decode, QR payload + digits, HKDF, advert decrypt, domain derivation, Noise KNpsk0, framing. Unit-tested against self-made vectors and an in-process *simulated phone* (the responder side) over a loopback WebSocket "tunnel" bound to 127.0.0.1.
2. BLE scanner (CoreBluetooth), scanning only while the sheet is open, filtered to service FFF9, never storing names or identifiers. Needs `NSBluetoothAlwaysUsageDescription` and the non-restricted `com.apple.security.device.bluetooth` entitlement (build script + `Browser.entitlements`).
3. WebAuthn bridge: page script overriding `navigator.credentials.create/get`, a message handler that takes the **origin from WebKit's frame info** (never from the page), rpId suffix check, secure context only, top frame only, builds `clientDataJSON` and the CTAP request, returns a real `PublicKeyCredential`-shaped object (attestation "none").
4. UI: a sheet with the QR code, status text, Cancel; times out in 2 minutes.
5. Evidence: loopback end-to-end test in the stress harness (simulated phone + loopback tunnel + real WebKit page calling `navigator.credentials.get`), then your real iPhone against a public passkey demo site. The real-phone run is the only proof of interop; I cannot do it without you.

## Risks, honestly
- The phone/Apple side is not under my control: if Apple's QR handler rejects something unspecified in the spec, only a real-phone run shows it.
- Cloud tunnel: traffic goes through Apple's / Google's tunnel servers (end-to-end encrypted by Noise; they see metadata only).
- Bluetooth permission prompt appears once, on first use.
- Public-network safe: no mDNS/AirPlay; BLE scanning only during the sheet; outbound HTTPS/WSS only.
- Creating passkeys (makeCredential) from a phone-held credential works the same way; discoverable-credential and "conditional UI" autofill are not part of this (modal sheet only).
