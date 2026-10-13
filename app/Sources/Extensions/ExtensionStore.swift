import CryptoKit
import Foundation
import Security

/// Downloading extensions from the official stores, with integrity checks. HTTPS only, official hosts only, size-capped.
/// Chrome Web Store: the CRX3 developer signature is verified and the extension id derived from the signing key must equal the id asked for.
/// Firefox Add-ons: the file's SHA-256 must equal the hash the add-ons API published for that exact file.
public enum ExtensionStore {
  public enum Source: Equatable, Sendable { case chrome(id: String), firefox(slug: String) }
  public enum StoreError: Error, Equatable { case unrecognised, badHost(String), http(Int), tooLarge, badResponse(String), badSignature(String), idMismatch(expected: String, actual: String), hashMismatch }

  /// Accepts a Chrome Web Store URL or bare 32-letter id, or a Firefox Add-ons URL.
  public static func parse(_ text: String) -> Source? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    func isChromeID(_ s: String) -> Bool { s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) } }
    if isChromeID(t) { return .chrome(id: t) }
    guard let u = URL(string: t), u.scheme == "https", let host = u.host?.lowercased() else { return nil }
    let parts = u.pathComponents.filter { $0 != "/" }
    if host == "chromewebstore.google.com" || host == "chrome.google.com", let id = parts.last(where: isChromeID) { return .chrome(id: id) }
    if host == "addons.mozilla.org", let i = parts.firstIndex(of: "addon"), i + 1 < parts.count, !parts[i + 1].isEmpty {
      let slug = parts[i + 1]; if !slug.allSatisfy({ $0 == "." }), slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) { return .firefox(slug: slug) }
    }
    return nil
  }

  static let allowedHosts: Set<String> = ["clients2.google.com", "clients2.googleusercontent.com", "addons.mozilla.org", "addons.cdn.mozilla.net"]
  public static let maxBytes = 200 << 20

  /// Downloads and verifies; returns a local file ready for `ExtensionPackage.prepare`.
  public static func download(_ s: Source, into dir: URL, fetch: (@Sendable (URL) async throws -> Data)? = nil) async throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let get = fetch ?? { try await httpGet($0) }
    switch s {
    case .chrome(let id):
      var c = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
      c.queryItems = [.init(name: "response", value: "redirect"), .init(name: "prodversion", value: "130.0.0.0"), .init(name: "acceptformat", value: "crx3"), .init(name: "x", value: "id=\(id)&installsource=ondemand&uc")]
      let data = try await get(c.url!)
      let actual = try CrxVerifier.verify(data)
      guard actual == id else { throw StoreError.idMismatch(expected: id, actual: actual) }
      let f = dir.appendingPathComponent("\(id).crx"); try data.write(to: f, options: .atomic); return f
    case .firefox(let slug):
      let meta = try await get(URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!)
      guard let j = try? JSONSerialization.jsonObject(with: meta) as? [String: Any], let file = (j["current_version"] as? [String: Any])?["file"] as? [String: Any],
            let urlStr = file["url"] as? String, let u = URL(string: urlStr), let hash = file["hash"] as? String, hash.hasPrefix("sha256:") else { throw StoreError.badResponse("add-on metadata") }
      let data = try await get(u)
      guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash.dropFirst(7).lowercased() else { throw StoreError.hashMismatch }
      let f = dir.appendingPathComponent("\(slug).xpi"); try data.write(to: f, options: .atomic); return f
    }
  }

  /// HTTPS GET with an ephemeral session (no cookies, no cache), redirects only inside the official hosts, size-capped.
  public static func httpGet(_ url: URL) async throws -> Data {
    guard url.scheme == "https", let h = url.host, allowedHosts.contains(h) else { throw StoreError.badHost(url.host ?? "?") }
    let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 30; cfg.timeoutIntervalForResource = 180; cfg.httpCookieStorage = nil
    let session = URLSession(configuration: cfg, delegate: RedirectGuard(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (bytes, resp) = try await session.bytes(from: url)
    guard let http = resp as? HTTPURLResponse else { throw StoreError.badResponse("not HTTP") }
    guard http.statusCode == 200 else { throw StoreError.http(http.statusCode) }
    if http.expectedContentLength > Int64(maxBytes) { throw StoreError.tooLarge }
    var data = Data()
    for try await b in bytes { data.append(b); if data.count > maxBytes { throw StoreError.tooLarge } }
    return data
  }
  private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest req: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
      if let u = req.url, u.scheme == "https", let h = u.host, ExtensionStore.allowedHosts.contains(h) { completionHandler(req) } else { completionHandler(nil) }
    }
  }
}

/// CRX3 verification (Chrome extension package signature). Returns the 32-letter extension id (a–p) derived from the developer's public key.
public enum CrxVerifier {
  public static func verify(_ d: Data) throws -> String {
    typealias E = ExtensionStore.StoreError
    func u32(_ at: Int) -> Int? { d.count >= at + 4 ? Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24 : nil }
    guard d.starts(with: Array("Cr24".utf8)), u32(4) == 3, let hl = u32(8), 12 + hl <= d.count else { throw E.badSignature("not a CRX3 file") }
    let header = d.subdata(in: 12..<(12 + hl)), zip = d.subdata(in: (12 + hl)..<d.count)
    var rsa: [(key: Data, sig: Data)] = [], ec: [(key: Data, sig: Data)] = [], signed = Data()
    var r = Proto(header)
    while let (field, bytes) = try r.next() {
      switch field {
      case 2, 3: var p = Proto(bytes); var key = Data(), sig = Data(); while let (f, b) = try p.next() { if f == 1 { key = b } else if f == 2 { sig = b } }
        if field == 2 { rsa.append((key, sig)) } else { ec.append((key, sig)) }
      case 10000: signed = bytes
      default: break
      }
    }
    var sid = Data(); var sp = Proto(signed); while let (f, b) = try sp.next() { if f == 1 { sid = b } }
    guard sid.count == 16 else { throw E.badSignature("missing crx id") }
    var payload = Data("CRX3 SignedData\0".utf8)
    var len = UInt32(signed.count).littleEndian; withUnsafeBytes(of: &len) { payload.append(contentsOf: $0) }
    payload.append(signed); payload.append(zip)
    var ok = false
    for (key, sig) in rsa + ec {
      guard Data(SHA256.hash(data: key)).prefix(16) == sid else { continue }                // the developer proof: its key must be the one the id is derived from
      let isRSA = rsa.contains { $0.key == key }
      guard let raw = spkiKeyBytes(key), let secKey = makeKey(raw, rsa: isRSA) else { continue }
      let alg: SecKeyAlgorithm = isRSA ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
      if SecKeyVerifySignature(secKey, alg, payload as CFData, sig as CFData, nil) { ok = true; break }
    }
    guard ok else { throw E.badSignature("developer signature does not verify") }
    return String(sid.flatMap { [$0 >> 4, $0 & 15] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
  }

  struct Proto {
    let d: Data; var i = 0
    init(_ d: Data) { self.d = d }
    mutating func varint() throws -> Int { var v = 0, s = 0; while i < d.count { let b = Int(d[i]); i += 1; v |= (b & 0x7f) << s; if b & 0x80 == 0 { return v }; s += 7; if s > 56 { break } }; throw ExtensionStore.StoreError.badSignature("bad protobuf") }
    mutating func next() throws -> (Int, Data)? {
      guard i < d.count else { return nil }
      let tag = try varint(), wire = tag & 7
      guard wire == 2 else { if wire == 0 { _ = try varint(); return try next() }; throw ExtensionStore.StoreError.badSignature("unsupported protobuf wire type") }
      let n = try varint(); guard n >= 0, i + n <= d.count else { throw ExtensionStore.StoreError.badSignature("bad protobuf length") }
      defer { i += n }; return (tag >> 3, d.subdata(in: i..<(i + n)))
    }
  }
  /// SubjectPublicKeyInfo -> the raw key bytes inside its BIT STRING (PKCS#1 for RSA, X9.63 point for EC).
  static func spkiKeyBytes(_ spki: Data) -> Data? {
    var i = 0; let b = [UInt8](spki)
    func len() -> Int? { guard i < b.count else { return nil }; let f = Int(b[i]); i += 1; if f < 0x80 { return f }; let n = f & 0x7f; guard n >= 1, n <= 3, i + n <= b.count else { return nil }; var v = 0; for _ in 0..<n { v = v << 8 | Int(b[i]); i += 1 }; return v }
    guard i < b.count, b[i] == 0x30 else { return nil }; i += 1; guard len() != nil, i < b.count, b[i] == 0x30 else { return nil }; i += 1
    guard let algLen = len() else { return nil }; i += algLen
    guard i < b.count, b[i] == 0x03 else { return nil }; i += 1; guard let bl = len(), bl > 1, i + bl <= b.count, b[i] == 0 else { return nil }
    return spki.subdata(in: (i + 1)..<(i + bl))
  }
  static func makeKey(_ raw: Data, rsa: Bool) -> SecKey? {
    let attrs: [CFString: Any] = [kSecAttrKeyType: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic]
    return SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, nil)
  }
}
