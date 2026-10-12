import BrowserCore
import Foundation
import SQLite3

public enum StoreError: Error, Equatable { case open(String), sql(String), corrupt(String), schemaTooNew(Int), mustLoadFirst }

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Crash-safe session store (master prompt §18): WAL, one transaction per save, versioned schema, user-only file modes.
/// Holds browser metadata only. Web data (cookies etc.) stays in WebKit's data stores; secrets stay in Keychain.
///
/// Safety contract: an existing database must be `load()`ed successfully (or `quarantineAndReset()` after a failed load)
/// before `save()` is allowed, so a read failure can never be followed by an empty save that wipes the user's sessions.
public final class Store: @unchecked Sendable {
  public static let schemaVersion = 3
  private var db: OpaquePointer?
  private let lock = NSLock()
  private let path: String
  private var _canSave = false
  private var canSave: Bool { get { lock.lock(); defer { lock.unlock() }; return _canSave } set { lock.lock(); _canSave = newValue; lock.unlock() } }

  public init(path: String) throws {
    self.path = path
    // A zero-length main file next to a non-empty WAL is NOT a fresh database (the WAL may hold committed data).
    let walBytes = ((try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? Int) ?? 0
    let hadWAL = walBytes > 0
    var h: OpaquePointer?
    guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
      let m = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"; sqlite3_close(h); throw StoreError.open(m)
    }
    db = h
    sqlite3_busy_timeout(h, 3000)
    do {
      try exec("PRAGMA journal_mode=WAL"); try exec("PRAGMA synchronous=FULL"); try exec("PRAGMA foreign_keys=ON"); try exec("PRAGMA secure_delete=ON")
      let fresh = try migrate()
      _canSave = fresh && !hadWAL
      secureFiles()
    } catch { sqlite3_close(h); db = nil; throw error }
  }
  deinit { if let db { sqlite3_close(db) } }

  /// Browsing history lives here: keep the database and its WAL/SHM files private to the user.
  private func secureFiles() { for suffix in ["", "-wal", "-shm"] { chmod(path + suffix, 0o600) } }

  // MARK: schema
  private func userVersionLocked() throws -> Int {
    var v = 0
    try queryLocked("PRAGMA user_version") { v = Int(sqlite3_column_int($0, 0)) }
    return v
  }
  /// Returns true if this database was created just now (empty, safe to save into).
  private func migrate() throws -> Bool {
    var wasFresh = false
    try transaction {                                   // version is read INSIDE the write lock: no migration race between processes
      let v = try userVersionLocked()
      if v > Store.schemaVersion { throw StoreError.schemaTooNew(v) }
      wasFresh = v == 0
      if v < 1 {
        try execLocked("""
        CREATE TABLE space(id TEXT PRIMARY KEY, name TEXT NOT NULL, profile TEXT NOT NULL, ord INTEGER NOT NULL);
        CREATE TABLE tab(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, url TEXT NOT NULL,
          title TEXT NOT NULL, pinned INTEGER NOT NULL, last_active REAL NOT NULL, ord INTEGER NOT NULL);
        CREATE TABLE window(id TEXT PRIMARY KEY, space TEXT NOT NULL REFERENCES space(id) ON DELETE CASCADE, selected TEXT, ord INTEGER NOT NULL);
        CREATE TABLE window_last(window TEXT NOT NULL REFERENCES window(id) ON DELETE CASCADE, space TEXT NOT NULL, tab TEXT NOT NULL, PRIMARY KEY(window, space));
        CREATE TABLE setting(key TEXT PRIMARY KEY, value BLOB NOT NULL);
        """)
      }
      if v < 2 {   // v2: closing tabs sleeps them (archive) instead of deleting
        try execLocked("""
        CREATE TABLE archive(id TEXT PRIMARY KEY, space TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
          pinned INTEGER NOT NULL, closed_at REAL NOT NULL, idx INTEGER NOT NULL, ord INTEGER NOT NULL);
        """)
      }
      if v < 3 {   // v3: archive remembers profile + original lastActive; per-tab restore state blobs (history/scroll) survive restarts
        try execLocked("""
        ALTER TABLE archive ADD COLUMN profile TEXT;
        ALTER TABLE archive ADD COLUMN last_active REAL;
        CREATE TABLE tab_state(tab TEXT PRIMARY KEY, state BLOB NOT NULL, updated REAL NOT NULL);
        """)
      }
      if v < Store.schemaVersion { try execLocked("PRAGMA user_version = \(Store.schemaVersion)") }
    }
    return wasFresh
  }

  // MARK: state
  public func save(_ s: BrowserState) throws {
    guard canSave else { throw StoreError.mustLoadFirst }
    let bad = s.validate(); if !bad.isEmpty { throw StoreError.corrupt("refusing to save invalid state: \(bad[0])") }
    try transaction {
      try execLocked("DELETE FROM window_last; DELETE FROM window; DELETE FROM tab; DELETE FROM space; DELETE FROM archive;")
      for (i, sp) in s.spaces.enumerated() {
        try run("INSERT INTO space(id,name,profile,ord) VALUES(?,?,?,?)", [.text(sp.id.raw.uuidString), .text(sp.name), .text(sp.profile.raw.uuidString), .int(i)])
        for (j, tid) in sp.tabOrder.enumerated() {
          let t = s.tabs[tid]!
          try run("INSERT INTO tab(id,space,url,title,pinned,last_active,ord) VALUES(?,?,?,?,?,?,?)",
                  [.text(tid.raw.uuidString), .text(sp.id.raw.uuidString), .text(t.url), .text(t.title), .int(t.pinned ? 1 : 0), .real(t.lastActive.timeIntervalSinceReferenceDate), .int(j)])
        }
      }
      for (i, w) in s.windows.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }).enumerated() {
        try run("INSERT INTO window(id,space,selected,ord) VALUES(?,?,?,?)", [.text(w.id.raw.uuidString), .text(w.space.raw.uuidString), w.selected.map { .text($0.raw.uuidString) } ?? .null, .int(i)])
        for (sp, tab) in w.lastSelected { try run("INSERT INTO window_last(window,space,tab) VALUES(?,?,?)", [.text(w.id.raw.uuidString), .text(sp.raw.uuidString), .text(tab.raw.uuidString)]) }
      }
      for (i, a) in s.archive.enumerated() {
        try run("INSERT INTO archive(id,space,url,title,pinned,closed_at,idx,ord,profile,last_active) VALUES(?,?,?,?,?,?,?,?,?,?)",
                [.text(a.id.raw.uuidString), .text(a.space.raw.uuidString), .text(a.url), .text(a.title), .int(a.pinned ? 1 : 0), .real(a.closedAt.timeIntervalSinceReferenceDate), .int(a.index), .int(i),
                 a.profile.map { .text($0.raw.uuidString) } ?? .null, .real(a.lastActive.timeIntervalSinceReferenceDate)])
      }
    }
    secureFiles()
  }

  /// Consistent snapshot (single read transaction). Marks the store safe to save into on success.
  public func load() throws -> BrowserState {
    lock.lock(); defer { lock.unlock() }
    func uuid(_ s: String) throws -> UUID { guard let u = UUID(uuidString: s) else { throw StoreError.corrupt("bad uuid \(s)") }; return u }
    var spaces: [Space] = [], tabs: [TabRecord] = [], windows: [BrowserWindow] = [], archive: [ArchivedTab] = []
    var order: [SpaceID: [TabID]] = [:]
    var err: Error?
    try execLocked("BEGIN")
    defer { if (try? execLocked("COMMIT")) == nil { try? execLocked("ROLLBACK") } }
    try queryLocked("SELECT id,name,profile FROM space ORDER BY ord") { st in
      if err != nil { return }
      do { spaces.append(Space(id: SpaceID(try uuid(col(st, 0))), name: col(st, 1), profile: ProfileID(try uuid(col(st, 2))))) } catch { err = error }
    }
    try queryLocked("SELECT id,space,url,title,pinned,last_active FROM tab ORDER BY space, ord") { st in
      if err != nil { return }
      do {
        let sid = SpaceID(try uuid(col(st, 1))), tid = TabID(try uuid(col(st, 0)))
        tabs.append(TabRecord(id: tid, space: sid, url: col(st, 2), title: col(st, 3), pinned: sqlite3_column_int(st, 4) != 0, lastActive: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 5))))
        order[sid, default: []].append(tid)
      } catch { err = error }
    }
    try queryLocked("SELECT id,space,selected FROM window ORDER BY ord") { st in
      if err != nil { return }
      do {
        let sel: TabID? = sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : TabID(try uuid(col(st, 2)))
        windows.append(BrowserWindow(id: WindowID(try uuid(col(st, 0))), space: SpaceID(try uuid(col(st, 1))), selected: sel))
      } catch { err = error }
    }
    try queryLocked("SELECT window,space,tab FROM window_last") { st in
      if err != nil { return }
      do {
        let wid = WindowID(try uuid(col(st, 0)))
        guard let i = windows.firstIndex(where: { $0.id == wid }) else { err = StoreError.corrupt("window_last for unknown window"); return }
        windows[i].lastSelected[SpaceID(try uuid(col(st, 1)))] = TabID(try uuid(col(st, 2)))
      } catch { err = error }
    }
    try queryLocked("SELECT id,space,url,title,pinned,closed_at,idx,profile,last_active FROM archive ORDER BY ord") { st in
      if err != nil { return }
      do {
        let prof: ProfileID? = sqlite3_column_type(st, 7) == SQLITE_NULL ? nil : ProfileID(try uuid(col(st, 7)))
        let closed = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 5))
        let last: Date? = sqlite3_column_type(st, 8) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 8))
        archive.append(ArchivedTab(id: TabID(try uuid(col(st, 0))), space: SpaceID(try uuid(col(st, 1))), url: col(st, 2), title: col(st, 3), pinned: sqlite3_column_int(st, 4) != 0,
                                   closedAt: closed, index: Int(sqlite3_column_int(st, 6)), profile: prof, lastActive: last))
      } catch { err = error }
    }
    if let err { throw err }
    for i in spaces.indices { spaces[i].tabOrder = order[spaces[i].id] ?? [] }
    let state = BrowserState(spaces: spaces, tabs: tabs, windows: windows, archive: archive)
    let bad = state.validate(); if !bad.isEmpty { throw StoreError.corrupt(bad[0]) }
    _canSave = true
    return state
  }

  /// After a failed load: preserve the database aside (consistent `VACUUM INTO` copy; if the file is too damaged for that,
  /// a raw byte copy of the db/WAL/SHM, fsynced), then clear it so the app can start clean. Nothing is silently destroyed.
  @discardableResult public func quarantineAndReset() throws -> String {
    lock.lock(); defer { lock.unlock() }
    let stamp = Int(Date().timeIntervalSince1970)
    var dest = "\(path).corrupt-\(stamp)"
    var n = 0; while FileManager.default.fileExists(atPath: dest) { n += 1; dest = "\(path).corrupt-\(stamp)-\(n)" }
    var saved = false
    do { try prepared("VACUUM INTO ?", [.text(dest)]) { _ in }; saved = true } catch { saved = false }
    if !saved {
      try? execLocked("PRAGMA wal_checkpoint(TRUNCATE)")
      for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
        try FileManager.default.copyItem(atPath: path + suffix, toPath: dest + suffix)
        if let fh = FileHandle(forWritingAtPath: dest + suffix) { try? fh.synchronize(); try? fh.close() }
        chmod(dest + suffix, 0o600)
      }
    } else { chmod(dest, 0o600); if let fh = FileHandle(forWritingAtPath: dest) { try? fh.synchronize(); try? fh.close() } }
    try execLocked("BEGIN IMMEDIATE")
    do { try execLocked("DELETE FROM window_last; DELETE FROM window; DELETE FROM tab; DELETE FROM space; DELETE FROM archive; DELETE FROM tab_state;"); try execLocked("COMMIT") } catch { try? execLocked("ROLLBACK"); throw error }
    _canSave = true
    return dest
  }

  // MARK: per-tab restore state (WebKit interactionState: history + scroll). Separate from BrowserState saves: big, changes often.
  public func setTabState(_ tab: TabID, _ state: Data?) throws {
    try transaction {
      if let st = state { try run("INSERT INTO tab_state(tab,state,updated) VALUES(?,?,?) ON CONFLICT(tab) DO UPDATE SET state=excluded.state, updated=excluded.updated", [.text(tab.raw.uuidString), .blob(st), .real(Date().timeIntervalSinceReferenceDate)]) }
      else { try run("DELETE FROM tab_state WHERE tab=?", [.text(tab.raw.uuidString)]) }
    }
  }
  public func tabState(_ tab: TabID) throws -> Data? {
    lock.lock(); defer { lock.unlock() }
    var out: Data?
    try queryLocked("SELECT state FROM tab_state WHERE tab=?", [.text(tab.raw.uuidString)]) { st in
      if let p = sqlite3_column_blob(st, 0) { out = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0))) } else { out = Data() }
    }
    return out
  }
  /// Drop restore states for tabs that no longer exist in `live` or the archive (housekeeping after saves).
  public func pruneTabStates(keeping ids: Set<TabID>) throws {
    var existing: [String] = []
    lock.lock(); try? queryLocked("SELECT tab FROM tab_state") { existing.append(self.col($0, 0)) }; lock.unlock()
    let keep = Set(ids.map { $0.raw.uuidString })
    try transaction { for t in existing where !keep.contains(t) { try run("DELETE FROM tab_state WHERE tab=?", [.text(t)]) } }
  }

  // MARK: settings (opaque blobs: policy config, usage model, ...)
  public func setSetting(_ key: String, _ value: Data) throws {
    try transaction { try run("INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .blob(value)]) }
  }
  public func setting(_ key: String) throws -> Data? {
    lock.lock(); defer { lock.unlock() }
    var out: Data?
    try queryLocked("SELECT value FROM setting WHERE key=?", [.text(key)]) { st in
      if let p = sqlite3_column_blob(st, 0) { out = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0))) } else { out = Data() }
    }
    return out
  }

  #if DEBUG
  /// Test hook: begin a write transaction and abandon the connection without commit or checkpoint.
  public func simulateAbandonedTransaction() throws {
    lock.lock(); defer { lock.unlock() }
    try execLocked("BEGIN IMMEDIATE; DELETE FROM tab; DELETE FROM space;")
    sqlite3_close_v2(db); db = nil
  }
  #endif

  // MARK: plumbing
  enum Bind { case text(String), int(Int), real(Double), blob(Data), null }
  private func col(_ st: OpaquePointer?, _ i: Int32) -> String {   // length-aware: embedded NULs must round-trip
    guard let p = sqlite3_column_text(st, i) else { return "" }
    return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(st, i))), as: UTF8.self)
  }
  private func msg() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

  private func transaction(_ body: () throws -> Void) throws {
    lock.lock(); defer { lock.unlock() }
    try execLocked("BEGIN IMMEDIATE")
    do { try body(); try execLocked("COMMIT") } catch { try? execLocked("ROLLBACK"); throw error }
  }
  private func exec(_ sql: String) throws { lock.lock(); defer { lock.unlock() }; try execLocked(sql) }
  private func execLocked(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(msg()) }
  }
  private func run(_ sql: String, _ binds: [Bind]) throws { try prepared(sql, binds) { _ in } }
  private func queryLocked(_ sql: String, _ binds: [Bind] = [], _ row: (OpaquePointer?) -> Void) throws { try prepared(sql, binds, row) }
  private func prepared(_ sql: String, _ binds: [Bind], _ row: (OpaquePointer?) -> Void) throws {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw StoreError.sql(msg()) }
    defer { sqlite3_finalize(st) }
    for (i, b) in binds.enumerated() {
      let n = Int32(i + 1)
      let rc: Int32
      switch b {
      case .text(let s): rc = s.utf8CString.withUnsafeBufferPointer { sqlite3_bind_text(st, n, $0.baseAddress, Int32($0.count - 1), SQLITE_TRANSIENT) }
      case .int(let v): rc = sqlite3_bind_int64(st, n, Int64(v))
      case .real(let v): rc = sqlite3_bind_double(st, n, v)
      case .blob(let d): rc = d.isEmpty ? sqlite3_bind_zeroblob(st, n, 0) : d.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
      case .null: rc = sqlite3_bind_null(st, n)
      }
      guard rc == SQLITE_OK else { throw StoreError.sql("bind \(n): \(msg())") }
    }
    while true {
      let rc = sqlite3_step(st)
      if rc == SQLITE_ROW { row(st) } else if rc == SQLITE_DONE { break } else { throw StoreError.sql(msg()) }
    }
  }
}
