import BrowserCore
import CryptoKit
import Foundation

/// Opt-in, local-only record of tab activations, used to tune the hibernation policy on the user's real habits.
/// Privacy (honest version): hosts and tab ids are stored only as salted SHA-256 prefixes, no URLs, no titles, file mode 0600,
/// never transmitted. This is PSEUDONYMIZATION, not anonymity: the salt lives in the same file, so anyone who can read the file
/// can test guesses like "google.com"; timestamps and stable tab hashes still reveal activity patterns. Disabled unless `enabled`.
/// Format: first line `#v1 salt=<hex>`, then `epochSeconds,tabHash,hostHash` per activation.
public final class UsageRecorder: @unchecked Sendable {
  public let enabled: Bool
  private let path: String
  private let maxBytes: Int
  private let lock = NSLock()
  private var salt: Data

  public init(path: String, enabled: Bool, maxBytes: Int = 5_000_000) throws {
    self.path = path; self.enabled = enabled; self.maxBytes = maxBytes
    self.salt = Data()
    guard enabled else { return }
    if FileManager.default.fileExists(atPath: path), ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0) > 0 {
      // Existing log: reuse its salt. NEVER overwrite a log we cannot parse (that would silently destroy data).
      guard let text = try? String(contentsOfFile: path, encoding: .utf8), let first = text.split(separator: "\n", maxSplits: 1).first,
            first.hasPrefix("#v1 salt="), let s = Data(hex: String(first.dropFirst("#v1 salt=".count))), s.count == 16
      else { throw StoreError.corrupt("usage log exists but its header is unreadable; refusing to overwrite") }
      salt = s
    } else {
      var bytes = [UInt8](repeating: 0, count: 16)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StoreError.sql("no random salt") }
      salt = Data(bytes)
      guard createPrivate(path, "#v1 salt=\(salt.hex)\n") else { throw StoreError.sql("cannot create usage log") }
    }
  }

  /// Create a file that is 0600 from its first byte (no world-readable window).
  private func createPrivate(_ p: String, _ text: String) -> Bool {
    FileManager.default.createFile(atPath: p, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
  }

  func hash(_ s: String) -> String {
    let d = SHA256.hash(data: salt + Data(s.utf8)); return d.prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  public func recordActivation(tab: TabID, host: String?, at: Date = Date()) {
    guard enabled else { return }
    lock.lock(); defer { lock.unlock() }
    let line = "\(Int(at.timeIntervalSince1970)),\(hash(tab.raw.uuidString)),\(hash(host ?? ""))\n"
    if !FileManager.default.fileExists(atPath: path) { _ = createPrivate(path, "#v1 salt=\(salt.hex)\n") }   // recreate with the same salt if it vanished
    if let h = FileHandle(forWritingAtPath: path) {
      defer { try? h.close() }
      do { try h.seekToEnd(); try h.write(contentsOf: Data(line.utf8)) } catch { return }
      if ((try? h.offset()) ?? 0) > UInt64(maxBytes) { rotateLocked() }
    }
  }

  /// Keep the header and the newest half of the records (atomic replace).
  private func rotateLocked() {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard let header = lines.first, header.hasPrefix("#v1") else { return }
    let body = lines.dropFirst(); let kept = body.suffix(body.count / 2)
    let tmp = path + ".tmp"
    guard createPrivate(tmp, ([header] + kept).joined(separator: "\n") + "\n") else { return }
    _ = rename(tmp, path)                       // atomic replace; tmp was 0600 from creation
  }

  public struct Event: Equatable, Sendable { public var time: Date, tab: String, host: String }
  /// Parse a recorded file (for the simulator / offline tuning). Malformed lines are skipped.
  public static func parse(_ text: String) -> [Event] {
    text.split(separator: "\n").compactMap { l in
      if l.hasPrefix("#") { return nil }
      let f = l.split(separator: ",", omittingEmptySubsequences: false)
      guard f.count == 3, let t = TimeInterval(f[0]) else { return nil }
      return Event(time: Date(timeIntervalSince1970: t), tab: String(f[1]), host: String(f[2]))
    }
  }
}

extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
  init?(hex: String) {
    guard hex.count % 2 == 0 else { return nil }
    var d = Data(); var i = hex.startIndex
    while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }; d.append(b); i = j }
    self = d
  }
}
