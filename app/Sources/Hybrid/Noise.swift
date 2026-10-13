import CryptoKit
import Foundation

/// Noise_KNpsk0_P256_AESGCM_SHA256 as used by the FIDO hybrid transport (client = initiator, authenticator = responder).
/// Sequence follows the CTAP 2.2 sample code: mixHash([1]); mixHash(initiator static, uncompressed); mixKeyAndHash(psk); ...
public enum Noise {
  public enum NoiseError: Error { case badMessage, authFailed, nonEmptyPayload }
  static let protocolName = "Noise_KNpsk0_P256_AESGCM_SHA256"

  struct Symmetric {
    var h: Data, ck: Data
    var k: SymmetricKey?; var n: UInt64 = 0
    init() { var d = Data(Noise.protocolName.utf8); d.append(Data(repeating: 0, count: 32 - d.count)); h = d; ck = d }   // name (31 bytes) zero-padded to the hash length
    mutating func mixHash(_ d: Data) { h = Data(SHA256.hash(data: h + d)) }
    mutating func mixKey(_ input: Data) { let o = Noise.hkdf(ck, input, 2); ck = o[0]; k = SymmetricKey(data: o[1]); n = 0 }
    mutating func mixKeyAndHash(_ input: Data) { let o = Noise.hkdf(ck, input, 3); ck = o[0]; mixHash(o[1]); k = SymmetricKey(data: o[2]); n = 0 }
    func nonce() throws -> AES.GCM.Nonce { var d = Data(repeating: 0, count: 4); for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((n >> UInt64(s)) & 0xff)) }; return try AES.GCM.Nonce(data: d) }
    mutating func encryptAndHash(_ pt: Data) throws -> Data {
      guard let k else { mixHash(pt); return pt }
      let box = try AES.GCM.seal(pt, using: k, nonce: nonce(), authenticating: h); n += 1
      let out = Data(box.ciphertext + box.tag); mixHash(out); return out
    }
    mutating func decryptAndHash(_ ct: Data) throws -> Data {
      guard let k else { mixHash(ct); return ct }
      guard ct.count >= 16 else { throw NoiseError.badMessage }
      let box = try AES.GCM.SealedBox(nonce: nonce(), ciphertext: ct.prefix(ct.count - 16), tag: ct.suffix(16))
      let pt: Data; do { pt = try AES.GCM.open(box, using: k, authenticating: h) } catch { throw NoiseError.authFailed }
      n += 1; mixHash(ct); return pt
    }
    func split() -> (SymmetricKey, SymmetricKey) { let o = Noise.hkdf(ck, Data(), 2); return (SymmetricKey(data: o[0]), SymmetricKey(data: o[1])) }
  }

  static func hmac(_ key: Data, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
  static func hkdf(_ ck: Data, _ input: Data, _ n: Int) -> [Data] {
    let temp = hmac(ck, input); var out: [Data] = []; var prev = Data()
    for i in 1...n { prev = hmac(temp, prev + Data([UInt8(i)])); out.append(prev) }
    return out
  }
  static func dh(_ priv: P256.KeyAgreement.PrivateKey, _ pub: P256.KeyAgreement.PublicKey) throws -> Data {
    try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
  }

  public struct Keys { public let send: SymmetricKey, receive: SymmetricKey; public let handshakeHash: Data }

  public final class Initiator {
    var s = Symmetric(); let staticKey: P256.KeyAgreement.PrivateKey; let ephemeral = P256.KeyAgreement.PrivateKey()
    public init(staticKey: P256.KeyAgreement.PrivateKey, psk: Data) {
      self.staticKey = staticKey
      s.mixHash(Data([1])); s.mixHash(staticKey.publicKey.x963Representation); s.mixKeyAndHash(psk)
    }
    public func firstMessage() throws -> Data {
      let e = ephemeral.publicKey.x963Representation
      s.mixHash(e); s.mixKey(e)
      return e + (try s.encryptAndHash(Data()))
    }
    public func finish(response: Data) throws -> Keys {
      guard response.count >= 65 + 16 else { throw NoiseError.badMessage }
      let reBytes = response.prefix(65), ct = response.dropFirst(65)
      guard let re = try? P256.KeyAgreement.PublicKey(x963Representation: reBytes) else { throw NoiseError.badMessage }
      s.mixHash(Data(reBytes)); s.mixKey(Data(reBytes))
      s.mixKey(try Noise.dh(ephemeral, re)); s.mixKey(try Noise.dh(staticKey, re))
      guard try s.decryptAndHash(Data(ct)).isEmpty else { throw NoiseError.nonEmptyPayload }
      let (k1, k2) = s.split(); return Keys(send: k1, receive: k2, handshakeHash: s.h)
    }
  }

  public final class Responder {
    var s = Symmetric(); let initiatorStatic: P256.KeyAgreement.PublicKey
    public init(initiatorStatic: P256.KeyAgreement.PublicKey, psk: Data) {
      self.initiatorStatic = initiatorStatic
      s.mixHash(Data([1])); s.mixHash(initiatorStatic.x963Representation); s.mixKeyAndHash(psk)
    }
    public func respond(to first: Data) throws -> (reply: Data, keys: Keys) {
      guard first.count >= 65 + 16 else { throw NoiseError.badMessage }
      let reBytes = first.prefix(65)
      guard let re = try? P256.KeyAgreement.PublicKey(x963Representation: reBytes) else { throw NoiseError.badMessage }
      s.mixHash(Data(reBytes)); s.mixKey(Data(reBytes))
      guard try s.decryptAndHash(Data(first.dropFirst(65))).isEmpty else { throw NoiseError.nonEmptyPayload }
      let e = P256.KeyAgreement.PrivateKey(); let eb = e.publicKey.x963Representation
      s.mixHash(eb); s.mixKey(eb)
      s.mixKey(try Noise.dh(e, re)); s.mixKey(try Noise.dh(e, initiatorStatic))
      let ct = try s.encryptAndHash(Data())
      let (k1, k2) = s.split()
      return (eb + ct, Keys(send: k2, receive: k1, handshakeHash: s.h))
    }
  }

  /// Post-handshake transport: AES-256-GCM, empty AAD, 32-bit big-endian counter in the last 4 bytes of a 12-byte nonce, 32-byte padding granularity.
  public final class Cipher {
    let keys: Keys; var sendCounter: UInt32 = 0, receiveCounter: UInt32 = 0
    public init(_ keys: Keys) { self.keys = keys }
    func nonce(_ c: UInt32) throws -> AES.GCM.Nonce { var d = Data(repeating: 0, count: 8); for s in stride(from: 24, through: 0, by: -8) { d.append(UInt8((c >> UInt32(s)) & 0xff)) }; return try AES.GCM.Nonce(data: d) }
    public func seal(_ message: Data) throws -> Data {
      guard sendCounter < 1 << 24 else { throw NoiseError.badMessage }
      let box = try AES.GCM.seal(Hybrid.pad(message), using: keys.send, nonce: nonce(sendCounter)); sendCounter += 1
      return Data(box.ciphertext + box.tag)
    }
    public func open(_ wire: Data) throws -> Data {
      guard wire.count >= 16, receiveCounter < 1 << 24 else { throw NoiseError.badMessage }
      let box = try AES.GCM.SealedBox(nonce: nonce(receiveCounter), ciphertext: wire.prefix(wire.count - 16), tag: wire.suffix(16))
      let pt: Data; do { pt = try AES.GCM.open(box, using: keys.receive) } catch { throw NoiseError.authFailed }
      receiveCounter += 1
      guard let m = Hybrid.unpad(pt) else { throw NoiseError.badMessage }
      return m
    }
  }
}
