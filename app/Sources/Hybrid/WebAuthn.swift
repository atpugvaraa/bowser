import CryptoKit
import Foundation

/// WebAuthn <-> CTAP2 translation for the browser side. Pure functions (the page bridge calls these after validating origin and rpId).
public enum Passkey {
  public enum PasskeyError: Error, Equatable { case invalid(String), notAllowed(String) }

  // MARK: base64url
  public static func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
  public static func fromB64url(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
  }

  // MARK: origin / rpId (the origin always comes from WebKit's frame info, never from the page)
  /// True if `rpId` is the page's host or a registrable-looking parent of it. IP addresses and bare top-level names are refused.
  public static func rpIdAllowed(rpId: String, originHost: String) -> Bool {
    let rp = rpId.lowercased(), host = originHost.lowercased()
    guard !rp.isEmpty, rp.count <= 253, rp.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return false }
    if rp.split(separator: ".").allSatisfy({ Int($0) != nil }) { return false }                  // IPv4
    guard host == rp || host.hasSuffix("." + rp) else { return false }
    if rp == "localhost" { return true }
    let labels = rp.split(separator: ".")
    guard labels.count >= 2 else { return false }
    let publicSuffixes: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "co.jp", "co.in", "com.br", "co.nz", "github.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "web.app", "appspot.com", "cloudfront.net", "blogspot.com"]
    return !publicSuffixes.contains(rp)
  }
  public static func originString(scheme: String, host: String, port: Int) -> String? {
    let s = scheme.lowercased(), h = host.lowercased()
    guard s == "https" || (s == "http" && (h == "localhost" || h == "127.0.0.1")) else { return nil }
    let def = s == "https" ? 443 : 80
    return port == 0 || port == def ? "\(s)://\(h)" : "\(s)://\(h):\(port)"
  }

  public static func clientDataJSON(type: String, challenge: Data, origin: String) -> Data {
    func esc(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.flatMap { u -> [Unicode.Scalar] in u == "\"" || u == "\\" ? ["\\", u] : [u] })) }
    return Data("{\"type\":\"\(type)\",\"challenge\":\"\(b64url(challenge))\",\"origin\":\"\(esc(origin))\",\"crossOrigin\":false}".utf8)
  }

  // MARK: CTAP requests
  public struct Descriptor { public var id: Data; public init(id: Data) { self.id = id } }
  public static func getAssertionRequest(rpId: String, clientDataHash: Data, allow: [Descriptor], userVerification: String) -> Data {
    var m: [(CBOR, CBOR)] = [(.int(1), .text(rpId)), (.int(2), .bytes(clientDataHash))]
    if !allow.isEmpty { m.append((.int(3), .array(allow.map { .map([(.text("type"), .text("public-key")), (.text("id"), .bytes($0.id))]) }))) }
    if userVerification != "discouraged" { m.append((.int(5), .map([(.text("uv"), .bool(true))]))) }
    return Data([0x02]) + CBOR.map(m).encode()
  }
  public static func makeCredentialRequest(rpId: String, rpName: String, userId: Data, userName: String, displayName: String, clientDataHash: Data, algs: [Int64], exclude: [Descriptor], residentKey: String, userVerification: String) -> Data {
    var m: [(CBOR, CBOR)] = [
      (.int(1), .bytes(clientDataHash)),
      (.int(2), .map([(.text("id"), .text(rpId)), (.text("name"), .text(rpName.isEmpty ? rpId : rpName))])),
      (.int(3), .map([(.text("id"), .bytes(userId)), (.text("name"), .text(userName)), (.text("displayName"), .text(displayName))])),
      (.int(4), .array((algs.isEmpty ? [-7, -257] : algs).map { .map([(.text("alg"), .int($0)), (.text("type"), .text("public-key"))]) }))]
    if !exclude.isEmpty { m.append((.int(5), .array(exclude.map { .map([(.text("type"), .text("public-key")), (.text("id"), .bytes($0.id))]) }))) }
    var opts: [(CBOR, CBOR)] = []
    if residentKey == "required" || residentKey == "preferred" { opts.append((.text("rk"), .bool(true))) }
    if userVerification != "discouraged" { opts.append((.text("uv"), .bool(true))) }
    if !opts.isEmpty { m.append((.int(7), .map(opts))) }
    return Data([0x01]) + CBOR.map(m).encode()
  }

  // MARK: CTAP responses -> the dictionaries the page expects (all binary as base64url)
  public static func assertionResult(ctapResponse: Data, clientDataJSON: Data) throws -> [String: Any] {
    guard ctapResponse.first == 0, let m = try? CBOR.decode(ctapResponse.dropFirst()),
          let credId = m[1]?["id"]?.data, let authData = m[2]?.data, let sig = m[3]?.data else { throw PasskeyError.invalid("assertion response") }
    var r: [String: Any] = ["id": b64url(credId), "rawId": b64url(credId), "authenticatorData": b64url(authData), "signature": b64url(sig), "clientDataJSON": b64url(clientDataJSON)]
    if let uid = m[4]?["id"]?.data { r["userHandle"] = b64url(uid) }
    return r
  }
  public static func creationResult(ctapResponse: Data, clientDataJSON: Data) throws -> [String: Any] {
    guard ctapResponse.first == 0, let m = try? CBOR.decode(ctapResponse.dropFirst()), let fmt = m[1]?.string, let authData = m[2]?.data, let attStmt = m[3] else { throw PasskeyError.invalid("creation response") }
    guard authData.count > 55, authData[32] & 0x40 != 0 else { throw PasskeyError.invalid("no credential data in authenticator data") }
    let idLen = Int(authData[53]) << 8 | Int(authData[54]); guard authData.count >= 55 + idLen else { throw PasskeyError.invalid("credential id length") }
    let credId = authData.subdata(in: 55..<(55 + idLen))
    let attObj = CBOR.map([(.text("fmt"), .text(fmt)), (.text("attStmt"), attStmt), (.text("authData"), .bytes(authData))]).encode()
    var r: [String: Any] = ["id": b64url(credId), "rawId": b64url(credId), "attestationObject": b64url(attObj), "authenticatorData": b64url(authData), "clientDataJSON": b64url(clientDataJSON)]
    if let (cose, _) = try? CBOR.decodePrefix(authData.dropFirst(55 + idLen).asData), let x = cose[-2]?.data, let y = cose[-3]?.data, x.count == 32, y.count == 32,
       let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y) {
      r["publicKey"] = b64url(key.derRepresentation); r["publicKeyAlgorithm"] = Int(cose[3]?.integer ?? -7)
    }
    return r
  }
}
extension Data.SubSequence { var asData: Data { Data(self) } }
