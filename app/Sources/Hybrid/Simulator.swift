import CryptoKit
import Foundation

// Test doubles: an in-memory tunnel relay, a fake BLE source and a software "phone" that speaks the authenticator side of the protocol.
// Used by CoreChecks / EngineStress to prove the client end to end without a real phone. They prove self-consistency with the spec, not interop with Apple's phone.

public final class LoopbackTunnel: HybridTunnel, @unchecked Sendable {
  private let lock = NSLock()
  private var inbox: [Data] = [], waiter: CheckedContinuation<Data, Error>?, closed = false
  var peer: LoopbackTunnel?
  public init() {}
  public func send(_ d: Data) async throws { guard let p = peer, !closed else { throw HybridError.tunnel("closed") }; p.deliver(d) }
  func deliver(_ d: Data) { lock.lock(); if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: d) } else { inbox.append(d); lock.unlock() } }
  public func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { c in
      lock.lock()
      if !inbox.isEmpty { let d = inbox.removeFirst(); lock.unlock(); c.resume(returning: d) }
      else if closed { lock.unlock(); c.resume(throwing: HybridError.tunnel("closed")) }
      else { waiter = c; lock.unlock() }
    }
  }
  public func close() { lock.lock(); closed = true; let w = waiter; waiter = nil; lock.unlock(); w?.resume(throwing: HybridError.tunnel("closed")) }
}

public final class LoopbackHub: @unchecked Sendable {
  private let lock = NSLock(); private var pending: [String: LoopbackTunnel] = [:]
  public private(set) var connections: [URL] = []
  public init() {}
  public func connect(_ url: URL) async throws -> HybridTunnel { join(url) }
  private func join(_ url: URL) -> HybridTunnel {
    lock.lock(); defer { lock.unlock() }
    connections.append(url)
    if let other = pending.removeValue(forKey: url.path) { let t = LoopbackTunnel(); t.peer = other; other.peer = t; return t }
    let t = LoopbackTunnel(); pending[url.path] = t; return t
  }
}

public final class SimulatedBLE: AdvertSource, @unchecked Sendable {
  private let lock = NSLock(); private var cont: AsyncStream<Data>.Continuation?; private var buffered: [Data] = []
  public init() {}
  public func adverts() -> AsyncStream<Data> {
    AsyncStream { c in lock.lock(); cont = c; let b = buffered; buffered = []; lock.unlock(); for d in b { c.yield(d) } }
  }
  public func emit(_ d: Data) { lock.lock(); if let c = cont { lock.unlock(); c.yield(d) } else { buffered.append(d); lock.unlock() } }
}

/// A software FIDO authenticator (what the iPhone is): ES256 credentials, "none" attestation.
public final class SoftwareAuthenticator: @unchecked Sendable {
  struct Cred { let rpId: String; let id: Data; let key: P256.Signing.PrivateKey; let user: Data; var count: UInt32 }
  var creds: [Cred] = []; public var approve = true
  public init() {}
  public var credentialCount: Int { creds.count }
  public func handle(_ req: Data) -> Data {
    guard approve else { return Data([0x27]) }                                    // CTAP2_ERR_OPERATION_DENIED
    guard let cmd = req.first, let m = try? CBOR.decode(req.dropFirst()) else { return Data([0x12]) }
    if cmd == 0x01 { return makeCredential(m) }
    if cmd == 0x02 { return getAssertion(m) }
    return Data([0x01])
  }
  func authData(rpId: String, flags: UInt8, count: UInt32, attested: (Data, Data)? = nil) -> Data {
    var d = Data(SHA256.hash(data: Data(rpId.utf8))) + Data([flags]) + Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
    if let (id, cose) = attested { d += Data(repeating: 0, count: 16) + Data([UInt8(id.count >> 8), UInt8(id.count & 255)]) + id + cose }
    return d
  }
  func makeCredential(_ m: CBOR) -> Data {
    guard let rp = m[2]?["id"]?.string, let user = m[3]?["id"]?.data else { return Data([0x14]) }
    let key = P256.Signing.PrivateKey(); var id = [UInt8](repeating: 0, count: 32); _ = SecRandomCopyBytes(kSecRandomDefault, 32, &id)
    let x963 = key.publicKey.x963Representation
    let cose = CBOR.map([(.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)), (.int(-2), .bytes(x963.subdata(in: 1..<33))), (.int(-3), .bytes(x963.subdata(in: 33..<65)))]).encode()
    creds.append(Cred(rpId: rp, id: Data(id), key: key, user: user, count: 0))
    let ad = authData(rpId: rp, flags: 0x45 | 0x08 | 0x10, count: 0, attested: (Data(id), cose))        // UP, UV, AT, BE, BS (a synced passkey)
    return Data([0]) + CBOR.map([(.int(1), .text("none")), (.int(2), .bytes(ad)), (.int(3), .map([]))]).encode()
  }
  func getAssertion(_ m: CBOR) -> Data {
    guard let rp = m[1]?.string, let hash = m[2]?.data else { return Data([0x14]) }
    let allowed = m[3]?.items?.compactMap { $0["id"]?.data }
    guard let i = creds.firstIndex(where: { $0.rpId == rp && (allowed == nil || allowed!.contains($0.id)) }) else { return Data([0x2E]) }   // NO_CREDENTIALS
    creds[i].count += 1
    let ad = authData(rpId: rp, flags: 0x05 | 0x08 | 0x10, count: creds[i].count)
    let sig = try! creds[i].key.signature(for: ad + hash).derRepresentation
    return Data([0]) + CBOR.map([(.int(1), .map([(.text("id"), .bytes(creds[i].id)), (.text("type"), .text("public-key"))])), (.int(2), .bytes(ad)), (.int(3), .bytes(sig)), (.int(4), .map([(.text("id"), .bytes(creds[i].user))]))]).encode()
  }
}

public final class SimulatedPhone: @unchecked Sendable {
  public let authenticator: SoftwareAuthenticator; let hub: LoopbackHub; let ble: SimulatedBLE
  public var domainID = 1; public var corruptAdvert = false
  public init(authenticator: SoftwareAuthenticator, hub: LoopbackHub, ble: SimulatedBLE) { self.authenticator = authenticator; self.hub = hub; self.ble = ble }

  /// "Scan" the QR code: emit the BLE advert, join the tunnel, answer one CTAP request.
  public func scan(_ qrURL: String) async throws {
    guard qrURL.hasPrefix("FIDO:/"), let raw = Hybrid.undigits(String(qrURL.dropFirst(6))), let qr = try? CBOR.decode(raw),
          let pubBytes = qr[0]?.data, let secret = qr[1]?.data, let pub = try? P256.KeyAgreement.PublicKey(compressedRepresentation: pubBytes) else { throw HybridError.badMessage("QR") }
    let eidKey = Hybrid.derive(secret, .eidKey, count: 64), tunnelID = Hybrid.derive(secret, .tunnelID, count: 16)
    var rnd = [UInt8](repeating: 0, count: 13); _ = SecRandomCopyBytes(kSecRandomDefault, 13, &rnd)
    let routing = Data(rnd[10...12])
    let plain = Hybrid.advertPlaintext(nonce: Data(rnd[0..<10]), routingID: routing, domainID: domainID)
    var adv = Hybrid.encryptAdvert(plaintext: plain, eidKey: eidKey)!
    if corruptAdvert { adv[19] ^= 1 }
    ble.emit(adv)
    guard let dom = Hybrid.tunnelDomain(domainID), let url = Hybrid.tunnelURL(domain: dom, routingID: routing, tunnelID: tunnelID) else { throw HybridError.badMessage("tunnel") }
    let tunnel = try await hub.connect(url)
    defer { tunnel.close() }
    let hs = Noise.Responder(initiatorStatic: pub, psk: Hybrid.derive(secret, .psk, salt: plain, count: 32))
    let (reply, keys) = try hs.respond(to: try await tunnel.receive())
    try await tunnel.send(reply)
    let cipher = Noise.Cipher(keys)
    try await tunnel.send(try cipher.seal(CBOR.map([(.int(1), .bytes(CBOR.map([(.int(1), .array([.text("FIDO_2_0")]))]).encode())), (.int(3), .array([.text("ctap")]))]).encode()))
    let m = try cipher.open(try await tunnel.receive())
    guard m.first == 1 else { throw HybridError.badMessage("expected CTAP") }
    try await tunnel.send(try cipher.seal(Data([1]) + authenticator.handle(Data(m.dropFirst()))))
    _ = try? await tunnel.receive()                                              // shutdown
  }
}
