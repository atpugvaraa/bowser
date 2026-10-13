import CommonCrypto
import CryptoKit
import Foundation

/// FIDO CTAP 2.2 §11.5 hybrid transport, QR-initiated, client side. Pure functions; no I/O.
public enum Hybrid {
  public static let serviceUUID = "0000FFF9-0000-1000-8000-00805F9B34FB"
  public static let knownDomains = 2                                  // cable.ua5v.com, cable.auth.com

  // MARK: QR payload
  public struct QR {
    public let identity: P256.KeyAgreement.PrivateKey
    public let secret: Data                                           // 16 bytes
    public let flow: String                                           // "ga" or "mc"
    public let time: Int
    public init(flow: String, identity: P256.KeyAgreement.PrivateKey = .init(), secret: Data? = nil, time: Int = Int(Date().timeIntervalSince1970)) {
      self.flow = flow; self.identity = identity; self.time = time
      if let s = secret { self.secret = s } else { var g = SystemRandomNumberGenerator(); self.secret = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }) }
    }
    public var cbor: CBOR {
      .map([(.int(0), .bytes(identity.publicKey.compressedRepresentation)), (.int(1), .bytes(secret)), (.int(2), .int(Int64(Hybrid.knownDomains))), (.int(3), .int(Int64(time))), (.int(4), .bool(false)), (.int(5), .text(flow))])
    }
    public var url: String { "FIDO:/" + Hybrid.digits(cbor.encode()) }
  }

  /// 7-byte little-endian chunks -> 17 digits; remainders of 1...6 bytes -> 3,5,8,10,13,15 digits.
  public static func digits(_ d: Data) -> String {
    let tail = [0: 0, 1: 3, 2: 5, 3: 8, 4: 10, 5: 13, 6: 15]
    var out = ""; var i = 0; let b = [UInt8](d)
    while i < b.count {
      let n = min(7, b.count - i); var v: UInt64 = 0
      for k in (0..<n).reversed() { v = v << 8 | UInt64(b[i + k]) }
      let width = n == 7 ? 17 : tail[n]!
      let s = String(v); out += String(repeating: "0", count: max(0, width - s.count)) + s; i += n
    }
    return out
  }
  public static func undigits(_ s: String) -> Data? {
    let widthToBytes = [17: 7, 15: 6, 13: 5, 10: 4, 8: 3, 5: 2, 3: 1]
    var out = Data(); var i = s.startIndex
    while i < s.endIndex {
      let remaining = s.distance(from: i, to: s.endIndex)
      let w = remaining >= 17 ? 17 : remaining
      guard let n = widthToBytes[w], let end = s.index(i, offsetBy: w, limitedBy: s.endIndex), var v = UInt64(s[i..<end]) else { return nil }
      for _ in 0..<n { out.append(UInt8(v & 0xff)); v >>= 8 }
      guard v == 0 else { return nil }
      i = end
    }
    return out
  }

  // MARK: key derivation
  public enum Purpose: UInt32 { case eidKey = 1, tunnelID = 2, psk = 3 }
  public static func derive(_ secret: Data, _ purpose: Purpose, salt: Data = Data(), count: Int) -> Data {
    var info = purpose.rawValue.littleEndian; let infoData = withUnsafeBytes(of: &info) { Data($0) }
    let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: infoData, outputByteCount: count)
    return k.withUnsafeBytes { Data($0) }
  }

  // MARK: BLE advert
  public struct Advert { public let plaintext: Data; public let nonce: Data; public let routingID: Data; public let tunnelDomainID: Int }
  public static func decryptAdvert(_ service: Data, eidKey: Data) -> Advert? {
    guard service.count == 20, eidKey.count == 64 else { return nil }
    let ct = service.prefix(16), tag = service.suffix(4)
    let mac = Data(HMAC<SHA256>.authenticationCode(for: ct, using: SymmetricKey(data: eidKey.suffix(32))).prefix(4))
    var diff: UInt8 = 0; for (a, b) in zip(mac, tag) { diff |= a ^ b }
    guard diff == 0, let pt = aesECB(Data(ct), key: Data(eidKey.prefix(32)), encrypt: false), pt[pt.startIndex] == 0 else { return nil }
    let p = [UInt8](pt)
    return Advert(plaintext: pt, nonce: Data(p[1...10]), routingID: Data(p[11...13]), tunnelDomainID: Int(p[14]) | Int(p[15]) << 8)
  }
  /// Authenticator / test side.
  public static func encryptAdvert(plaintext: Data, eidKey: Data) -> Data? {
    guard plaintext.count == 16, eidKey.count == 64, let ct = aesECB(plaintext, key: Data(eidKey.prefix(32)), encrypt: true) else { return nil }
    return ct + Data(HMAC<SHA256>.authenticationCode(for: ct, using: SymmetricKey(data: eidKey.suffix(32))).prefix(4))
  }
  public static func advertPlaintext(nonce: Data, routingID: Data, domainID: Int) -> Data {
    Data([0]) + nonce + routingID + Data([UInt8(domainID & 0xff), UInt8((domainID >> 8) & 0xff)])
  }
  static func aesECB(_ block: Data, key: Data, encrypt: Bool) -> Data? {
    guard block.count == 16, key.count == 32 else { return nil }
    var out = [UInt8](repeating: 0, count: 16); var moved = 0
    let status = block.withUnsafeBytes { b in key.withUnsafeBytes { k in
      CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), k.baseAddress, 32, nil, b.baseAddress, 16, &out, 16, &moved) } }
    return status == kCCSuccess && moved == 16 ? Data(out) : nil
  }

  // MARK: tunnel
  public static func tunnelDomain(_ id: Int) -> String? {
    if id == 0 { return "cable.ua5v.com" }
    if id == 1 { return "cable.auth.com" }
    guard id >= 256, id <= 0xffff else { return nil }                 // 2...255 are unassigned
    var input = Data("caBLEv2 tunnel server domain".utf8); input.append(UInt8(id & 0xff)); input.append(UInt8(id >> 8)); input.append(0)
    let digest = Array(SHA256.hash(data: input))
    var v: UInt64 = 0; for k in (0..<8).reversed() { v = v << 8 | UInt64(digest[k]) }
    let tld = [".com", ".org", ".net", ".info"][Int(v & 3)]; v >>= 2
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567"); var name = ""
    while v != 0 { name.append(alphabet[Int(v & 31)]); v >>= 5 }
    return "cable." + name + tld
  }
  public static func tunnelURL(domain: String, routingID: Data, tunnelID: Data) -> URL? {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    return URL(string: "wss://\(domain)/cable/connect/\(hex(routingID))/\(hex(tunnelID))")
  }

  // MARK: padded message framing (after the handshake)
  public static func pad(_ m: Data) -> Data {
    let n = (32 - (m.count + 1) % 32) % 32
    return m + Data(repeating: 0, count: n) + Data([UInt8(n)])
  }
  public static func unpad(_ m: Data) -> Data? {
    guard let last = m.last else { return nil }
    let n = Int(last); guard m.count >= n + 1 else { return nil }
    return m.prefix(m.count - n - 1)
  }
}
