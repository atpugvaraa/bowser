import BrowserCore
import Foundation

/// Launch/shutdown reliability around the Store: recovery order (main -> newest valid backup -> quarantine+clean),
/// debounced saves with retry, a fixed ring of rolling backups (overwritten in place, never deleted), tab restore-state blobs.
///
/// Golden rule: ONLY real corruption (StoreError.isCorruption) ever triggers recovery. Busy/locked, newer-schema, I/O and
/// disk-full errors are thrown to the caller with every file untouched.
@MainActor
public final class SessionManager {
  public enum Recovery: Equatable, Sendable {
    case clean
    case restoredFromBackup(slot: Int, backupAge: TimeInterval)   // age = how much recent history the backup could not contain
    case quarantined(path: String)
  }
  public let path: String
  public static let backupSlots = 3
  public private(set) var store: Store
  public private(set) var lastSaveError: Error?
  public var onSaveFailure: ((Error) -> Void)?
  private var pending: DispatchWorkItem?
  private var latest: BrowserState?
  private var pendingStates: [TabID: Data] = [:]        // blobs whose write failed; retried on every flush
  private var lastBackup: Date = .distantPast
  private let debounce: TimeInterval
  public var retryBase: TimeInterval = 5            // first retry delay after a failed save (doubles up to 5 min); tests lower it
  private var retryDelay: TimeInterval = 0

  public static func start(path: String, debounce: TimeInterval = 1.5) throws -> (SessionManager, BrowserState, Recovery) {
    func slotPath(_ i: Int) -> String { "\(path).backup-\(i)" }
    do {
      let s = try Store(path: path); let state = try s.load()
      return (SessionManager(path: path, store: s, debounce: debounce), state, .clean)
    } catch let e as StoreError where e.isCorruption {
      // fall through to recovery: the file itself is damaged
    }                                                    // any other error (busy, schemaTooNew, I/O...) propagates: nothing was touched
    for i in slotOrder(path: path) where FileManager.default.fileExists(atPath: slotPath(i)) {
      guard let b = try? Store(path: slotPath(i)), b.isHealthy(), (try? b.load()) != nil else { continue }
      let age = Date().timeIntervalSince(((try? FileManager.default.attributesOfItem(atPath: slotPath(i)))?[.modificationDate] as? Date) ?? Date())
      _ = try copyAsideAndTruncate(path: path)           // keep the damaged bytes, reset in place
      try b.backup(toPath: path)                         // whole DB incl. tab_state blobs, not just the model
      let fresh = try Store(path: path); let state = try fresh.load()
      return (SessionManager(path: path, store: fresh, debounce: debounce), state, .restoredFromBackup(slot: i, backupAge: age))
    }
    let q = try copyAsideAndTruncate(path: path)
    let clean = try Store(path: path)
    return (SessionManager(path: path, store: clean, debounce: debounce), BrowserState(), .quarantined(path: q))
  }

  private init(path: String, store: Store, debounce: TimeInterval) { self.path = path; self.store = store; self.debounce = debounce }

  /// Slots newest-first. The sidecar names the newest; if it is missing/garbled, order by file modification time.
  private static func slotOrder(path: String) -> [Int] {
    let fm = FileManager.default
    if let cur = (try? String(contentsOfFile: path + ".backup-current", encoding: .utf8)).flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), (0..<backupSlots).contains(cur) {
      return (0..<backupSlots).map { (cur - $0 + backupSlots * 2) % backupSlots }
    }
    return (0..<backupSlots).sorted { a, b in
      let ma = (try? fm.attributesOfItem(atPath: "\(path).backup-\(a)"))?[.modificationDate] as? Date ?? .distantPast
      let mb = (try? fm.attributesOfItem(atPath: "\(path).backup-\(b)"))?[.modificationDate] as? Date ?? .distantPast
      return ma > mb
    }
  }

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

  // MARK: saving
  /// Debounced save. Failures are remembered (`lastSaveError`), reported (`onSaveFailure`) and RETRIED with backoff; the state is never dropped.
  public func scheduleSave(_ state: BrowserState) {
    latest = state; pending?.cancel()
    let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.attemptFlush() } }
    pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: w)
  }
  private func attemptFlush() {
    do { try flush(); lastSaveError = nil; retryDelay = 0 }
    catch {
      lastSaveError = error; onSaveFailure?(error)
      let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.attemptFlush() } }
      retryDelay = retryDelay == 0 ? retryBase : min(retryDelay * 2, 300)
      pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: w)
    }
  }
  /// Write the latest scheduled state (and any blobs that failed earlier) now. Throws if the state cannot be written; `latest` is kept.
  public func flush() throws {
    pending?.cancel(); pending = nil
    if let s = latest { try store.save(s); latest = nil }
    for (id, d) in pendingStates { try store.setTabState(id, d); pendingStates[id] = nil }
  }
  public func save(_ state: BrowserState) throws { pending?.cancel(); pending = nil; latest = state; try flush() }

  // MARK: backups
  /// Copy the live DB into the next ring slot, only if it passes `quick_check` (never poison the ring with a damaged copy).
  @discardableResult public func rotateBackup() throws -> Int? {
    guard store.isHealthy() else { return nil }
    let cur = (try? String(contentsOfFile: path + ".backup-current", encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let slot: Int
    if let c = cur, (0..<Self.backupSlots).contains(c) { slot = (c + 1) % Self.backupSlots }
    else {                                           // no usable sidecar: overwrite the OLDEST existing slot (or slot 0 if none exist)
      let existing = (0..<Self.backupSlots).filter { FileManager.default.fileExists(atPath: "\(path).backup-\($0)") }
      slot = existing.isEmpty ? 0 : (Self.slotOrder(path: path).last(where: { existing.contains($0) }) ?? 0)
    }
    try store.backup(toPath: "\(path).backup-\(slot)")
    try "\(slot)\n".write(toFile: path + ".backup-current", atomically: true, encoding: .utf8)
    chmod(path + ".backup-current", 0o600); lastBackup = Date()
    return slot
  }
  /// Rotate at most once per `interval` (call from maintenance).
  public func rotateBackupIfDue(interval: TimeInterval = 1800) { if Date().timeIntervalSince(lastBackup) >= interval { _ = try? rotateBackup() } }

  // MARK: tab restore state (history/scroll)
  /// Never throws: a failed write is queued and retried on the next flush (so closing a tab cannot lose its history to a transient error).
  public func persistTabState(_ id: TabID, _ data: Data?) {
    do { try store.setTabState(id, data); pendingStates[id] = nil } catch { if let d = data { pendingStates[id] = d }; lastSaveError = error }
  }
  /// `failed == true` means the read errored (do NOT overwrite the stored blob from a fresh, shorter history).
  public func tabStateResult(_ id: TabID) -> (data: Data?, failed: Bool) {
    if let p = pendingStates[id] { return (p, false) }
    do { return (try store.tabState(id), false) } catch { return (nil, true) }
  }
  public func tabState(_ id: TabID) -> Data? { tabStateResult(id).data }
  public func pruneTabStates(keeping ids: Set<TabID>) { try? store.pruneTabStates(keeping: ids) }
}
