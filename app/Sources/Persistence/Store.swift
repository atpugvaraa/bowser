import BrowserCore
import Foundation
import SQLite3

public enum StoreError: Error, Equatable {
  case open(String), sql(String), corrupt(String), schemaTooNew(Int), mustLoadFirst
  case busy(String)             // locked by another connection/process: TRANSIENT, never a reason to touch the files
  case notADatabase(String)     // SQLITE_NOTADB / SQLITE_CORRUPT: the file itself is damaged
  /// Only these justify recovery from backup / quarantine. Everything else (busy, newer schema, I/O, disk full) must be surfaced untouched.
  public var isCorruption: Bool { switch self { case .corrupt, .notADatabase: return true; default: return false } }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Crash-safe session store (master prompt §18): WAL, one transaction per save, versioned schema, user-only file modes.
/// Holds browser metadata only. Web data (cookies etc.) stays in WebKit's data stores; secrets stay in Keychain.
///
/// Safety contract: an existing database must be `load()`ed successfully (or `quarantineAndReset()` after a failed load)
/// before `save()` is allowed, so a read failure can never be followed by an empty save that wipes the user's sessions.
public final class Store: @unchecked Sendable {
  public static let schemaVersion = 5
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
    let oldMask = umask(0o077); defer { umask(oldMask) }            // the database (and its WAL/SHM) are never even briefly group/world-readable
    var h: OpaquePointer?
    guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
      let m = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"; sqlite3_close(h); throw StoreError.open(m)
    }
    db = h
    sqlite3_busy_timeout(h, 3000)
    do {
      // Read-only probe FIRST: a database from a newer app version must not be modified at all (not even its journal mode).
      let v0 = try userVersionLocked()
      if v0 > Store.schemaVersion { throw StoreError.schemaTooNew(v0) }
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
      if v < 4 {   // v4: history (per profile, one row per URL with a visit counter) + bookmarks
        try execLocked("""
        CREATE TABLE history(profile TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, visits INTEGER NOT NULL, last_visited REAL NOT NULL, url_l TEXT NOT NULL, title_l TEXT NOT NULL, PRIMARY KEY(profile, url));       -- *_l: Swift-lowercased copies (SQLite lower() is ASCII-only)
        CREATE INDEX history_recent ON history(last_visited DESC);
        CREATE TABLE bookmark(id TEXT PRIMARY KEY, profile TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, added REAL NOT NULL, ord INTEGER NOT NULL);
        """)
      }
      if v < 5 { try execLocked("ALTER TABLE window ADD COLUMN frame TEXT") }     // v5: window position/size
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
        try run("INSERT INTO window(id,space,selected,ord,frame) VALUES(?,?,?,?,?)", [.text(w.id.raw.uuidString), .text(w.space.raw.uuidString), w.selected.map { .text($0.raw.uuidString) } ?? .null, .int(i), w.frame.map { .text($0.map { String($0) }.joined(separator: ",")) } ?? .null])
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
    try queryLocked("SELECT id,space,selected,frame FROM window ORDER BY ord") { st in
      if err != nil { return }
      do {
        let sel: TabID? = sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : TabID(try uuid(col(st, 2)))
        var win = BrowserWindow(id: WindowID(try uuid(col(st, 0))), space: SpaceID(try uuid(col(st, 1))), selected: sel)
        if sqlite3_column_type(st, 3) != SQLITE_NULL { let parts = col(st, 3).split(separator: ",").compactMap { Double($0) }; if parts.count == 4 { win.frame = parts } }
        windows.append(win)
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

  /// `PRAGMA quick_check`: true only if SQLite reports "ok".
  public func isHealthy() -> Bool {
    lock.lock(); defer { lock.unlock() }
    var ok = false
    try? queryLocked("PRAGMA quick_check(1)") { st in ok = (sqlite3_column_text(st, 0).map { String(cString: $0) } ?? "") == "ok" }
    return ok
  }

  /// Consistent online copy using SQLite's backup API; overwrites `dest` in place (so a fixed ring of slots needs no deletion).
  public func backup(toPath dest: String) throws {
    lock.lock(); defer { lock.unlock() }
    let oldMask = umask(0o077); defer { umask(oldMask) }
    var out: OpaquePointer?
    guard sqlite3_open_v2(dest, &out, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let out else {
      sqlite3_close(out); throw StoreError.open("backup destination: \(dest)")
    }
    defer { sqlite3_close(out) }
    guard let b = sqlite3_backup_init(out, "main", db, "main") else { throw StoreError.sql("backup init: \(String(cString: sqlite3_errmsg(out)))") }
    let rc = sqlite3_backup_step(b, -1); sqlite3_backup_finish(b)
    guard rc == SQLITE_DONE else { throw StoreError.sql("backup step rc=\(rc)") }
    chmod(dest, 0o600)
  }

  // MARK: history & bookmarks
  public struct HistoryEntry: Equatable, Sendable { public var profile: ProfileID, url: String, title: String, visits: Int, lastVisited: Date }
  public struct Bookmark: Equatable, Sendable { public var id: UUID, profile: ProfileID, url: String, title: String, added: Date }

  /// One transaction for a batch of visits: upsert, counting visits and keeping the newest non-empty title.
  public func recordVisits(_ visits: [(profile: ProfileID, url: String, title: String, at: Date)]) throws {
    guard !visits.isEmpty else { return }
    try transaction {
      for v in visits {
        try run("""
        INSERT INTO history(profile,url,title,visits,last_visited,url_l,title_l) VALUES(?,?,?,1,?,?,?)
        ON CONFLICT(profile,url) DO UPDATE SET visits = visits + 1, last_visited = MAX(last_visited, excluded.last_visited),
          title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END,
          title_l = CASE WHEN excluded.title <> '' THEN excluded.title_l ELSE title_l END
        """, [.text(v.profile.raw.uuidString), .text(v.url), .text(v.title), .real(v.at.timeIntervalSinceReferenceDate), .text(Fold.text(v.url)), .text(Fold.text(v.title))])
      }
    }
  }
  /// Update only the title of an existing entry (titles usually arrive after the visit was recorded).
  public func updateHistoryTitle(profile: ProfileID, url: String, title: String) throws {
    guard !title.isEmpty else { return }
    try transaction { try run("UPDATE history SET title = ?, title_l = ? WHERE profile = ? AND url = ?", [.text(title), .text(Fold.text(title)), .text(profile.raw.uuidString), .text(url)]) }
  }
  /// Every word must appear (case/diacritic-insensitive, plain substring: user input is never a LIKE pattern), newest first.
  /// Only the most recent `scanWindow` rows are considered so a huge history can never make typing slow.
  public func searchHistory(profile: ProfileID? = nil, words: [String], limit: Int = 50, scanWindow: Int = 20_000) throws -> [HistoryEntry] {
    lock.lock(); defer { lock.unlock() }
    var out: [HistoryEntry] = []
    let lim = min(max(limit, 1), 500)
    var inner = "SELECT profile,url,title,visits,last_visited,url_l,title_l FROM history"
    var binds: [Bind] = []
    if let p = profile { inner += " WHERE profile = ?"; binds.append(.text(p.raw.uuidString)) }
    inner += " ORDER BY last_visited DESC LIMIT \(min(max(scanWindow, 100), 1_000_000))"
    var sql = "SELECT profile,url,title,visits,last_visited FROM (\(inner))"
    let ws = words.map { Fold.text($0) }.filter { !$0.isEmpty }
    if !ws.isEmpty { sql += " WHERE " + ws.map { _ in "(instr(url_l, ?) > 0 OR instr(title_l, ?) > 0)" }.joined(separator: " AND "); for w in ws { binds.append(.text(w)); binds.append(.text(w)) } }
    sql += " LIMIT \(lim)"
    try queryLocked(sql, binds) { st in
      guard let pid = UUID(uuidString: col(st, 0)) else { return }
      out.append(HistoryEntry(profile: ProfileID(pid), url: col(st, 1), title: col(st, 2), visits: Int(sqlite3_column_int(st, 3)), lastVisited: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 4))))
    }
    return out
  }
  public func searchHistory(profile: ProfileID? = nil, query: String, limit: Int = 50) throws -> [HistoryEntry] { try searchHistory(profile: profile, words: QuickSearch.words(query), limit: limit) }
  public func historyCount() throws -> Int { lock.lock(); defer { lock.unlock() }; var n = 0; try queryLocked("SELECT COUNT(*) FROM history") { n = Int(sqlite3_column_int64($0, 0)) }; return n }

  public func addBookmark(profile: ProfileID, url: String, title: String, at: Date = Date()) throws -> UUID {
    let id = UUID()
    try transaction {
      var existing: String?
      try queryLocked("SELECT id FROM bookmark WHERE profile = ? AND url = ?", [.text(profile.raw.uuidString), .text(url)]) { existing = col($0, 0) }
      if existing != nil { return }                                    // already bookmarked: keep the original
      var next = 0; try queryLocked("SELECT COALESCE(MAX(ord), -1) + 1 FROM bookmark") { next = Int(sqlite3_column_int($0, 0)) }
      try run("INSERT INTO bookmark(id,profile,url,title,added,ord) VALUES(?,?,?,?,?,?)", [.text(id.uuidString), .text(profile.raw.uuidString), .text(url), .text(title), .real(at.timeIntervalSinceReferenceDate), .int(next)])
    }
    return (try? bookmarks(profile: profile).first { $0.url == url }?.id) ?? id
  }
  public func removeBookmark(_ id: UUID) throws { try transaction { try run("DELETE FROM bookmark WHERE id = ?", [.text(id.uuidString)]) } }
  public func bookmarks(profile: ProfileID? = nil) throws -> [Bookmark] {
    lock.lock(); defer { lock.unlock() }
    var out: [Bookmark] = []
    try queryLocked("SELECT id,profile,url,title,added FROM bookmark" + (profile == nil ? "" : " WHERE profile = ?") + " ORDER BY ord", profile.map { [.text($0.raw.uuidString)] } ?? []) { st in
      guard let i = UUID(uuidString: col(st, 0)), let p = UUID(uuidString: col(st, 1)) else { return }
      out.append(Bookmark(id: i, profile: ProfileID(p), url: col(st, 2), title: col(st, 3), added: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 4))))
    }
    return out
  }
  /// Explicit user action only ("Clear History"): there is no automatic deletion of history.
  public func clearHistory(profile: ProfileID? = nil) throws {
    try transaction { if let p = profile { try run("DELETE FROM history WHERE profile = ?", [.text(p.raw.uuidString)]) } else { try execLocked("DELETE FROM history") } }
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
    #if DEBUG
    if _failReads > 0 { _failReads -= 1; throw StoreError.sql("injected read failure") }
    #endif
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
  public var _failWrites = 0       // test hook: make the next N write transactions fail
  public var _failReads = 0        // test hook: make the next N tabState reads fail
  #endif
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
  private func fail(_ rc: Int32) -> StoreError {
    let m = msg()
    switch rc & 0xff { case SQLITE_BUSY, SQLITE_LOCKED: return .busy(m); case SQLITE_NOTADB, SQLITE_CORRUPT: return .notADatabase(m); default: return .sql(m) }
  }

  private func transaction(_ body: () throws -> Void) throws {
    lock.lock(); defer { lock.unlock() }
    #if DEBUG
    if _failWrites > 0 { _failWrites -= 1; throw StoreError.sql("injected write failure") }
    #endif
    try execLocked("BEGIN IMMEDIATE")
    do { try body(); try execLocked("COMMIT") } catch { try? execLocked("ROLLBACK"); throw error }
  }
  private func exec(_ sql: String) throws { lock.lock(); defer { lock.unlock() }; try execLocked(sql) }
  private func execLocked(_ sql: String) throws {
    let rc = sqlite3_exec(db, sql, nil, nil, nil)
    guard rc == SQLITE_OK else { throw fail(rc) }
  }
  private func run(_ sql: String, _ binds: [Bind]) throws { try prepared(sql, binds) { _ in } }
  private func queryLocked(_ sql: String, _ binds: [Bind] = [], _ row: (OpaquePointer?) -> Void) throws { try prepared(sql, binds, row) }
  private func prepared(_ sql: String, _ binds: [Bind], _ row: (OpaquePointer?) -> Void) throws {
    var st: OpaquePointer?
    let prc = sqlite3_prepare_v2(db, sql, -1, &st, nil)
    guard prc == SQLITE_OK else { throw fail(prc) }
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
      if rc == SQLITE_ROW { row(st) } else if rc == SQLITE_DONE { break } else { throw fail(rc) }
    }
  }
}
