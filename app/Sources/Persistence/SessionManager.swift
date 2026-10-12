import BrowserCore
import Foundation

/// Launch/shutdown reliability around the Store: recovery order (main -> newest valid backup -> quarantine+clean),
/// debounced saves, a fixed ring of rolling backups (overwritten in place, never deleted), and tab restore-state blobs.
@MainActor
public final class SessionManager {
  public enum Recovery: Equatable, Sendable { case clean, restoredFromBackup(slot: Int), quarantined(path: String) }
  public let path: String
  public static let backupSlots = 3
  public private(set) var store: Store
  private var pending: DispatchWorkItem?
  private var latest: BrowserState?
  private let debounce: TimeInterval

  /// Opens the store and recovers if needed. Never throws for corruption: it recovers or starts clean (keeping a quarantined copy).
  public static func start(path: String, debounce: TimeInterval = 1.5) throws -> (SessionManager, BrowserState, Recovery) {
    func slotPath(_ i: Int) -> String { "\(path).backup-\(i)" }
    if let s = try? Store(path: path), let state = try? s.load() { return (SessionManager(path: path, store: s, debounce: debounce), state, .clean) }
    // main DB unreadable: try the backups, newest first (slot index recorded in a tiny sidecar by rotateBackup)
    let order = Self.slotOrder(path: path)
    for i in order where FileManager.default.fileExists(atPath: slotPath(i)) {
      if let b = try? Store(path: slotPath(i)), let state = try? b.load() {
        // keep the broken main aside (byte copy), reset it in place, then rebuild main from the good backup
        _ = try Self.copyAsideAndTruncate(path: path)
        let fresh = try Store(path: path)
        _ = try? fresh.load()
        try fresh.save(state)
        return (SessionManager(path: path, store: fresh, debounce: debounce), state, .restoredFromBackup(slot: i))
      }
    }
    // nothing usable: keep a copy of whatever is there, reset in place, start clean
    let q = try Self.copyAsideAndTruncate(path: path)
    let clean = try Store(path: path)
    return (SessionManager(path: path, store: clean, debounce: debounce), BrowserState(), .quarantined(path: q))
  }

  /// Byte-copy the db (+WAL/SHM) to `<path>.corrupt-<ts>` (fsynced, 0600), then truncate the originals to zero length
  /// (a zero-length file is a valid empty SQLite database). Works even when the file is not a database at all.
  static func copyAsideAndTruncate(path: String) throws -> String {
    let stamp = Int(Date().timeIntervalSince1970)
    var dest = "\(path).corrupt-\(stamp)"; var n = 0
    while FileManager.default.fileExists(atPath: dest) { n += 1; dest = "\(path).corrupt-\(stamp)-\(n)" }
    for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
      try FileManager.default.copyItem(atPath: path + suffix, toPath: dest + suffix)
      if let fh = FileHandle(forWritingAtPath: dest + suffix) { try? fh.synchronize(); try? fh.close() }
      chmod(dest + suffix, 0o600)
    }
    for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
      let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path + suffix)); try fh.truncate(atOffset: 0); try fh.close()
    }
    return dest
  }

  private init(path: String, store: Store, debounce: TimeInterval) { self.path = path; self.store = store; self.debounce = debounce }

  private static func slotOrder(path: String) -> [Int] {
    let cur = (try? String(contentsOfFile: path + ".backup-current", encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    return (0..<backupSlots).map { (cur - $0 + backupSlots * 2) % backupSlots }     // newest first
  }

  /// Debounced save: coalesces bursts of changes into one transaction.
  public func scheduleSave(_ state: BrowserState) {
    latest = state; pending?.cancel()
    let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { try? self?.flush() } }
    pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: w)
  }
  /// Write the latest scheduled state now (call on quit / before sleep).
  public func flush() throws {
    pending?.cancel(); pending = nil
    if let s = latest { try store.save(s); latest = nil }
  }
  /// Immediate save of a given state.
  public func save(_ state: BrowserState) throws { pending?.cancel(); pending = nil; latest = nil; try store.save(state) }

  /// Copy the live DB into the next ring slot (overwrites the oldest slot in place; nothing is deleted).
  @discardableResult public func rotateBackup() throws -> Int {
    let cur = (try? String(contentsOfFile: path + ".backup-current", encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
    let next = (cur + 1) % Self.backupSlots
    try store.backup(toPath: "\(path).backup-\(next)")
    try "\(next)\n".write(toFile: path + ".backup-current", atomically: true, encoding: .utf8)
    chmod(path + ".backup-current", 0o600)
    return next
  }

  // MARK: tab restore state (history/scroll) — call when a tab hibernates and periodically for live tabs
  public func persistTabState(_ id: TabID, _ data: Data?) throws { try store.setTabState(id, data) }
  public func tabState(_ id: TabID) -> Data? { (try? store.tabState(id)) ?? nil }
}
