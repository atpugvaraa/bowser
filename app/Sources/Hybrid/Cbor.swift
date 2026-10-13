import Foundation

/// Minimal CBOR (RFC 8949) for CTAP2: unsigned/negative ints, byte/text strings, arrays, maps, bool, null. Definite lengths only.
public indirect enum CBOR: Equatable {
  case int(Int64), bytes(Data), text(String), array([CBOR]), map([(CBOR, CBOR)]), bool(Bool), null

  public static func == (a: CBOR, b: CBOR) -> Bool { a.encode() == b.encode() }

  public subscript(_ key: Int) -> CBOR? { if case .map(let m) = self { return m.first { if case .int(let k) = $0.0 { return k == Int64(key) }; return false }?.1 }; return nil }
  public subscript(_ key: String) -> CBOR? { if case .map(let m) = self { return m.first { if case .text(let k) = $0.0 { return k == key }; return false }?.1 }; return nil }
  public var data: Data? { if case .bytes(let d) = self { return d }; return nil }
  public var string: String? { if case .text(let s) = self { return s }; return nil }
  public var integer: Int64? { if case .int(let i) = self { return i }; return nil }
  public var items: [CBOR]? { if case .array(let a) = self { return a }; return nil }

  // MARK: encode (CTAP2 canonical: map keys ordered by length of their encoding, then bytewise)
  public func encode() -> Data {
    var out = Data()
    func head(_ major: UInt8, _ n: UInt64) {
      let m = major << 5
      switch n {
      case 0..<24: out.append(m | UInt8(n))
      case 24..<0x100: out.append(m | 24); out.append(UInt8(n))
      case 0x100..<0x10000: out.append(m | 25); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xff))
      case 0x10000..<0x1_0000_0000: out.append(m | 26); for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8((n >> UInt64(s)) & 0xff)) }
      default: out.append(m | 27); for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> UInt64(s)) & 0xff)) }
      }
    }
    switch self {
    case .int(let i): if i >= 0 { head(0, UInt64(i)) } else { head(1, UInt64(-1 - i)) }
    case .bytes(let d): head(2, UInt64(d.count)); out.append(d)
    case .text(let s): let u = Data(s.utf8); head(3, UInt64(u.count)); out.append(u)
    case .array(let a): head(4, UInt64(a.count)); for x in a { out.append(x.encode()) }
    case .map(let m):
      head(5, UInt64(m.count))
      for (k, v) in m.map({ ($0.0.encode(), $0.1.encode()) }).sorted(by: { $0.0.count != $1.0.count ? $0.0.count < $1.0.count : $0.0.lexicographicallyPrecedes($1.0) }) { out.append(k); out.append(v) }
    case .bool(let b): out.append(b ? 0xf5 : 0xf4)
    case .null: out.append(0xf6)
    }
    return out
  }

  // MARK: decode
  public enum DecodeError: Error { case truncated, unsupported, tooDeep, trailing }
  public static func decode(_ d: Data, allowTrailing: Bool = false) throws -> CBOR {
    var r = Reader(d); let v = try r.read(depth: 0)
    if !allowTrailing && r.i != d.count { throw DecodeError.trailing }
    return v
  }
  /// Decodes one value and returns how many bytes it used (authData may be followed by extra data).
  public static func decodePrefix(_ d: Data) throws -> (CBOR, Int) { var r = Reader(d); let v = try r.read(depth: 0); return (v, r.i) }

  struct Reader {
    let d: Data; var i = 0
    init(_ d: Data) { self.d = d }
    mutating func byte() throws -> UInt8 { guard i < d.count else { throw DecodeError.truncated }; defer { i += 1 }; return d[d.startIndex + i] }
    mutating func take(_ n: Int) throws -> Data { guard n >= 0, i + n <= d.count else { throw DecodeError.truncated }; defer { i += n }; return d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + n)) }
    mutating func arg(_ info: UInt8) throws -> UInt64 {
      switch info {
      case 0..<24: return UInt64(info)
      case 24: return UInt64(try byte())
      case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
      case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
      case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
      default: throw DecodeError.unsupported
      }
    }
    mutating func read(depth: Int) throws -> CBOR {
      guard depth < 16 else { throw DecodeError.tooDeep }
      let b = try byte(); let major = b >> 5, info = b & 31
      switch major {
      case 0: let n = try arg(info); guard n <= UInt64(Int64.max) else { throw DecodeError.unsupported }; return .int(Int64(n))
      case 1: let n = try arg(info); guard n <= UInt64(Int64.max) else { throw DecodeError.unsupported }; return .int(-1 - Int64(n))
      case 2: let n = try arg(info); guard n <= 1 << 24 else { throw DecodeError.unsupported }; return .bytes(try take(Int(n)))
      case 3: let n = try arg(info); guard n <= 1 << 24 else { throw DecodeError.unsupported }; return .text(String(decoding: try take(Int(n)), as: UTF8.self))
      case 4: let n = try arg(info); guard n <= 1 << 16 else { throw DecodeError.unsupported }; var a: [CBOR] = []; for _ in 0..<n { a.append(try read(depth: depth + 1)) }; return .array(a)
      case 5: let n = try arg(info); guard n <= 1 << 16 else { throw DecodeError.unsupported }; var m: [(CBOR, CBOR)] = []; for _ in 0..<n { let k = try read(depth: depth + 1); m.append((k, try read(depth: depth + 1))) }; return .map(m)
      case 6: _ = try arg(info); return try read(depth: depth + 1)           // tags are skipped
      case 7:
        switch info { case 20: return .bool(false); case 21: return .bool(true); case 22, 23: return .null; default: throw DecodeError.unsupported }
      default: throw DecodeError.unsupported
      }
    }
  }
}
