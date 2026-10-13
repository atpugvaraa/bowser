import Foundation

public struct ProfileID: Hashable, Sendable, Codable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw } }
public struct FolderID: Hashable, Sendable, Codable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw } }
public struct SpaceID: Hashable, Sendable, Codable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw } }
public struct WindowID: Hashable, Sendable, Codable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw } }

public struct FolderRecord: Sendable, Equatable {
  public var id: FolderID
  public var space: SpaceID
  public var name: String
  public var isExpanded: Bool
  public init(id: FolderID = FolderID(), space: SpaceID, name: String, isExpanded: Bool = true) {
    self.id = id; self.space = space; self.name = name; self.isExpanded = isExpanded
  }
}

public struct TabRecord: Sendable, Equatable {
  public var id: TabID
  public var space: SpaceID
  public var url: String
  public var title: String
  public var pinned: Bool
  public var folderId: FolderID?
  public var lastActive: Date
  public init(id: TabID = TabID(), space: SpaceID, url: String, title: String = "", pinned: Bool = false, folderId: FolderID? = nil, lastActive: Date = Date()) {
    self.id = id; self.space = space; self.url = url; self.title = title; self.pinned = pinned; self.folderId = folderId; self.lastActive = lastActive
  }
}

/// A closed tab. Closing never destroys: the tab sleeps here until restored or explicitly purged.
public struct ArchivedTab: Sendable, Equatable {
  public var id: TabID, space: SpaceID, url: String, title: String, pinned: Bool, closedAt: Date, index: Int
  public var profile: ProfileID?          // the profile the tab belonged to (nil only for rows archived before v3)
  public var lastActive: Date
  public init(id: TabID, space: SpaceID, url: String, title: String, pinned: Bool, closedAt: Date, index: Int, profile: ProfileID? = nil, lastActive: Date? = nil) {
    self.id = id; self.space = space; self.url = url; self.title = title; self.pinned = pinned; self.closedAt = closedAt; self.index = index
    self.profile = profile; self.lastActive = lastActive ?? closedAt
  }
}
public enum RestoreResult: Equatable, Sendable { case restored(TabID), needsProfileConfirmation(from: ProfileID?, to: ProfileID), notFound }

public struct ProfileRecord: Hashable, Sendable, Codable {
  public var id: ProfileID
  public var name: String
  public var icon: String?
  public init(id: ProfileID = ProfileID(), name: String, icon: String? = nil) {
    self.id = id; self.name = name; self.icon = icon
  }
}

public struct Space: Sendable, Equatable {
  public var id: SpaceID
  public var name: String
  public var icon: String
  public var profile: ProfileID
  public var colorHue: Double?
  public var tabOrder: [TabID] = []
  public var folderOrder: [FolderID] = []
  public init(id: SpaceID = SpaceID(), name: String, profile: ProfileID) {
    self.id = id; self.name = name; self.icon = "🪐"; self.profile = profile; self.colorHue = nil
  }
  public init(id: SpaceID = SpaceID(), name: String, icon: String, profile: ProfileID, colorHue: Double? = nil, folderOrder: [FolderID] = []) {
    self.id = id; self.name = name; self.icon = icon; self.profile = profile; self.colorHue = colorHue; self.folderOrder = folderOrder
  }
}

public struct BrowserWindow: Sendable, Equatable {
  public var id: WindowID
  public var space: SpaceID
  public var selected: TabID?
  public var lastSelected: [SpaceID: TabID] = [:]
  public var frame: [Double]?                     // x, y, width, height on screen (restored on relaunch); nil = let the app cascade it
  public init(id: WindowID = WindowID(), space: SpaceID, selected: TabID? = nil) { self.id = id; self.space = space; self.selected = selected }
}

public enum SelectResult: Equatable, Sendable { case selected, focusWindow(WindowID), notFound }
public enum MoveResult: Equatable, Sendable { case moved, needsProfileConfirmation(from: ProfileID, to: ProfileID), notFound }

/// Pure model of spaces, tabs and windows (see docs/architecture/window-model.md). No UI, no WebKit.
public struct BrowserState: Sendable, Equatable {
  public private(set) var profiles: [ProfileRecord] = []
  public private(set) var spaces: [Space] = []          // stable user order
  public private(set) var folders: [FolderID: FolderRecord] = [:]
  public private(set) var tabs: [TabID: TabRecord] = [:]
  public private(set) var windows: [WindowID: BrowserWindow] = [:]
  public private(set) var archive: [ArchivedTab] = []     // oldest first
  public init() {}
  public init(profiles: [ProfileRecord] = [], spaces: [Space], folders: [FolderRecord] = [], tabs: [TabRecord], windows: [BrowserWindow], archive: [ArchivedTab] = []) {
    self.archive = archive; self.spaces = spaces
    self.profiles = profiles.isEmpty ? Self.defaultProfiles(for: spaces) : profiles
    self.folders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    self.tabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) }); self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  }
  public init(profiles: [ProfileRecord] = [], spaces: [Space], tabs: [TabRecord], windows: [BrowserWindow], archive: [ArchivedTab] = []) {
    self.init(profiles: profiles, spaces: spaces, folders: [], tabs: tabs, windows: windows, archive: archive)
  }

  public static func defaultProfiles(for spaces: [Space]) -> [ProfileRecord] {
    var profs: [ProfileRecord] = []
    var seen = Set<ProfileID>()
    for (i, s) in spaces.enumerated() {
      if seen.insert(s.profile).inserted {
        profs.append(ProfileRecord(id: s.profile, name: i == 0 ? "Personal" : "Profile \(profs.count + 1)"))
      }
    }
    return profs
  }

  // MARK: profiles
  public func profile(_ id: ProfileID) -> ProfileRecord? { profiles.first { $0.id == id } }
  private func profileIndex(_ id: ProfileID) -> Int? { profiles.firstIndex { $0.id == id } }
  @discardableResult public mutating func addProfile(name: String, icon: String? = nil, id: ProfileID = ProfileID()) -> ProfileID {
    let p = ProfileRecord(id: id, name: name, icon: icon); profiles.append(p); return p.id
  }
  public mutating func updateProfile(_ id: ProfileID, name: String? = nil, icon: String? = nil) {
    guard let i = profileIndex(id) else { return }
    if let n = name { profiles[i].name = n }
    if let ic = icon { profiles[i].icon = ic }
  }
  @discardableResult public mutating func deleteProfile(_ id: ProfileID) -> Bool {
    guard profiles.count > 1, let i = profileIndex(id) else { return false }
    guard !spaces.contains(where: { $0.profile == id }) else { return false }
    profiles.remove(at: i)
    return true
  }

  // MARK: spaces
  public func space(_ id: SpaceID) -> Space? { spaces.first { $0.id == id } }
  private func spaceIndex(_ id: SpaceID) -> Int? { spaces.firstIndex { $0.id == id } }
  public var visibleTabs: Set<TabID> { Set(windows.values.compactMap(\.selected)) }
  public func windowShowing(_ tab: TabID, excluding: WindowID? = nil) -> WindowID? {
    windows.values.first { $0.selected == tab && $0.id != excluding }?.id
  }

  @discardableResult public mutating func addSpace(name: String, icon: String = "🪐", profile: ProfileID, colorHue: Double? = nil) -> SpaceID {
    if self.profile(profile) == nil {
      profiles.append(ProfileRecord(id: profile, name: profiles.isEmpty ? "Personal" : "Profile \(profiles.count + 1)"))
    }
    let s = Space(name: name, icon: icon, profile: profile, colorHue: colorHue); spaces.append(s); return s.id
  }
  @discardableResult public mutating func addSpace(name: String, profile: ProfileID) -> SpaceID {
    addSpace(name: name, icon: "🪐", profile: profile, colorHue: nil)
  }
  public mutating func updateSpace(_ id: SpaceID, name: String? = nil, icon: String? = nil, profile: ProfileID? = nil, colorHue: Double?? = nil) {
    guard let i = spaceIndex(id) else { return }
    if let n = name { spaces[i].name = n }
    if let ic = icon { spaces[i].icon = ic }
    if let p = profile {
      if self.profile(p) == nil { profiles.append(ProfileRecord(id: p, name: "Profile \(profiles.count + 1)")) }
      spaces[i].profile = p
    }
    if let ch = colorHue { spaces[i].colorHue = ch }
  }
  /// Needs another space to receive windows. Returns removed tabs (caller archives/cleans up engine state).
  @discardableResult public mutating func deleteSpace(_ id: SpaceID, now: Date = Date()) -> [TabRecord]? {
    guard spaces.count > 1, let i = spaceIndex(id) else { return nil }
    let removed = spaces[i].tabOrder.compactMap { tabs[$0] }
    for (j, t) in removed.enumerated() { archive.append(ArchivedTab(id: t.id, space: id, url: t.url, title: t.title, pinned: t.pinned, closedAt: now, index: j, profile: spaces[i].profile, lastActive: t.lastActive)); tabs[t.id] = nil }
    folders = folders.filter { $0.value.space != id }
    spaces.remove(at: i)
    let fallback = spaces[0].id
    for w in windows.keys where windows[w]!.space == id { switchSpace(window: w, to: fallback) }
    for w in windows.keys { windows[w]!.lastSelected[id] = nil }
    return removed
  }

  // MARK: folders
  public func folder(_ id: FolderID) -> FolderRecord? { folders[id] }
  public func folders(in space: SpaceID) -> [FolderRecord] {
    guard let sp = self.space(space) else { return [] }
    return sp.folderOrder.compactMap { folders[$0] }
  }
  @discardableResult public mutating func addFolder(in space: SpaceID, name: String, id: FolderID = FolderID()) -> FolderID? {
    guard let si = spaceIndex(space) else { return nil }
    let f = FolderRecord(id: id, space: space, name: name, isExpanded: true)
    folders[id] = f
    spaces[si].folderOrder.append(id)
    return id
  }
  public mutating func updateFolder(_ id: FolderID, name: String? = nil, isExpanded: Bool? = nil) {
    guard var f = folders[id] else { return }
    if let n = name { f.name = n }
    if let exp = isExpanded { f.isExpanded = exp }
    folders[id] = f
  }
  public mutating func toggleFolderExpanded(_ id: FolderID) {
    guard var f = folders[id] else { return }
    f.isExpanded = !f.isExpanded
    folders[id] = f
  }
  @discardableResult public mutating func deleteFolder(_ id: FolderID) -> Bool {
    guard let f = folders[id], let si = spaceIndex(f.space) else { return false }
    folders.removeValue(forKey: id)
    spaces[si].folderOrder.removeAll { $0 == id }
    for (tid, var t) in tabs where t.folderId == id {
      t.folderId = nil
      tabs[tid] = t
    }
    return true
  }
  public mutating func setTabFolder(tab: TabID, folder: FolderID?) {
    guard var t = tabs[tab] else { return }
    if let folder {
      guard let f = folders[folder], f.space == t.space else { return }
    }
    t.folderId = folder
    tabs[tab] = t
  }
  public mutating func setTabPinned(_ id: TabID, pinned: Bool) {
    guard var t = tabs[id] else { return }
    t.pinned = pinned
    if !pinned { t.folderId = nil }
    tabs[id] = t
  }

  // MARK: tabs
  @discardableResult public mutating func addTab(in space: SpaceID, url: String, title: String = "", at index: Int? = nil, now: Date = Date()) -> TabID? {
    guard let si = spaceIndex(space) else { return nil }
    let t = TabRecord(space: space, url: url, title: title, lastActive: now)
    tabs[t.id] = t
    let i = min(max(index ?? spaces[si].tabOrder.count, 0), spaces[si].tabOrder.count)
    spaces[si].tabOrder.insert(t.id, at: i)
    return t.id
  }

  /// Write live facts back into the record (current URL/title after navigation, real last-active time) so saves and the archive
  /// reflect what the user actually saw, not the creation URL.
  public mutating func updateTab(_ id: TabID, url: String? = nil, title: String? = nil, lastActive: Date? = nil) {
    guard var t = tabs[id] else { return }
    if let u = url, !u.isEmpty { t.url = u }
    if let ti = title { t.title = ti }
    if let la = lastActive { t.lastActive = la }
    tabs[id] = t
  }
  public mutating func purgeArchive(olderThan cutoff: Date, keepingBlobsFor: inout [TabID]) {
    keepingBlobsFor = archive.filter { $0.closedAt >= cutoff }.map(\.id)
    archive.removeAll { $0.closedAt < cutoff }
  }

  /// Sleeps the tab into the archive (never destroys). Use `restoreTab` to bring it back, `purge` to really delete.
  public mutating func closeTab(_ id: TabID, now: Date = Date()) {
    guard let t = tabs[id], let si = spaceIndex(t.space) else { return }
    let order = spaces[si].tabOrder
    let idx = order.firstIndex(of: id) ?? 0
    archive.append(ArchivedTab(id: id, space: t.space, url: t.url, title: t.title, pinned: t.pinned, closedAt: now, index: idx, profile: spaces[si].profile, lastActive: t.lastActive))
    spaces[si].tabOrder.removeAll { $0 == id }
    tabs[id] = nil
    for wid in windows.keys {
      windows[wid]!.lastSelected = windows[wid]!.lastSelected.filter { $0.value != id }
      if windows[wid]!.selected == id {
        windows[wid]!.selected = neighbour(in: spaces[si].tabOrder, near: idx, for: wid)
      }
    }
  }

  /// Bring a closed tab back. Target: its original space if it still exists, else a space with the SAME profile;
  /// restoring into a different profile (cookies/identity!) requires `confirmedCrossProfile`. Original lastActive is kept.
  @discardableResult public mutating func restoreTab(_ id: TabID, into dest: SpaceID? = nil, confirmedCrossProfile: Bool = false) -> RestoreResult {
    guard let ai = archive.firstIndex(where: { $0.id == id }), !spaces.isEmpty, tabs[id] == nil else { return .notFound }
    let a = archive[ai]
    var target: Int
    if let d = dest, let di = spaceIndex(d) { target = di }
    else if let o = spaceIndex(a.space) { target = o }
    else if let p = a.profile, let same = spaces.firstIndex(where: { $0.profile == p }) { target = same }
    else { target = 0 }
    if let p = a.profile, spaces[target].profile != p, !confirmedCrossProfile { return .needsProfileConfirmation(from: p, to: spaces[target].profile) }
    if a.profile == nil, !confirmedCrossProfile, spaceIndex(a.space) == nil { return .needsProfileConfirmation(from: nil, to: spaces[target].profile) }
    archive.remove(at: ai)
    let t = TabRecord(id: a.id, space: spaces[target].id, url: a.url, title: a.title, pinned: a.pinned, lastActive: a.lastActive)
    tabs[t.id] = t
    spaces[target].tabOrder.insert(t.id, at: min(max(a.index, 0), spaces[target].tabOrder.count))
    return .restored(t.id)
  }
  /// Explicit, user-requested permanent removal. The only path that loses a tab.
  public mutating func purge(_ id: TabID) { archive.removeAll { $0.id == id } }
  public mutating func purgeArchive(olderThan cutoff: Date) { archive.removeAll { $0.closedAt < cutoff } }

  /// Next tab, else previous, skipping tabs shown in other windows (and `skip`).
  private func neighbour(in order: [TabID], near idx: Int, for window: WindowID, skip: TabID? = nil) -> TabID? {
    let free = { (t: TabID) in t != skip && self.windowShowing(t, excluding: window) == nil }
    if idx < order.count { for t in order[idx...] where free(t) { return t } }
    for t in order[..<min(idx, order.count)].reversed() where free(t) { return t }
    return nil
  }

  public mutating func moveTab(_ id: TabID, to dest: SpaceID, confirmedCrossProfile: Bool = false) -> MoveResult {
    guard let t = tabs[id], let from = space(t.space), let to = space(dest), let fi = spaceIndex(from.id), let ti = spaceIndex(dest) else { return .notFound }
    if from.id == to.id { return .moved }
    if from.profile != to.profile && !confirmedCrossProfile { return .needsProfileConfirmation(from: from.profile, to: to.profile) }
    let idx = spaces[fi].tabOrder.firstIndex(of: id) ?? 0
    spaces[fi].tabOrder.removeAll { $0 == id }
    spaces[ti].tabOrder.append(id); tabs[id]!.space = dest
    for wid in windows.keys {
      windows[wid]!.lastSelected = windows[wid]!.lastSelected.filter { $0.value != id }
      if windows[wid]!.selected == id && windows[wid]!.space != dest {
        windows[wid]!.selected = neighbour(in: spaces[fi].tabOrder, near: idx, for: wid)
      }
    }
    return .moved
  }

  // MARK: windows
  @discardableResult public mutating func openWindow(space: SpaceID) -> WindowID? {
    guard let s = space_(space) else { return nil }
    var w = BrowserWindow(space: space)
    w.selected = s.tabOrder.first { windowShowing($0) == nil }
    windows[w.id] = w; return w.id
  }
  private func space_(_ id: SpaceID) -> Space? { space(id) }
  public mutating func closeWindow(_ id: WindowID) { windows[id] = nil }
  /// Remember where a window is (x, y, w, h). Ignores non-finite or absurd values.
  public mutating func setWindowFrame(_ id: WindowID, _ f: [Double]?) {
    guard windows[id] != nil else { return }
    if let f { guard f.count == 4, f.allSatisfy({ $0.isFinite && abs($0) < 100_000 }), f[2] >= 200, f[3] >= 150 else { return } }
    windows[id]?.frame = f
  }   // tabs are untouched (rule 1)

  public mutating func select(tab: TabID, in window: WindowID, now: Date = Date()) -> SelectResult {
    guard let t = tabs[tab], windows[window] != nil else { return .notFound }
    if let other = windowShowing(tab, excluding: window) { return .focusWindow(other) }
    if let cur = windows[window]!.selected, windows[window]!.space != t.space { windows[window]!.lastSelected[windows[window]!.space] = cur }
    windows[window]!.space = t.space; windows[window]!.selected = tab
    windows[window]!.lastSelected[t.space] = tab
    tabs[tab]!.lastActive = now
    return .selected
  }

  public mutating func switchSpace(window: WindowID, to dest: SpaceID) {
    guard var w = windows[window], let s = space(dest) else { return }
    if let cur = w.selected { w.lastSelected[w.space] = cur }
    w.space = dest
    let remembered = w.lastSelected[dest].flatMap { s.tabOrder.contains($0) && windowShowing($0, excluding: window) == nil ? $0 : nil }
    w.selected = remembered ?? s.tabOrder.first { windowShowing($0, excluding: window) == nil }
    windows[window] = w
  }

  /// Tear a tab off into its own window on the same Space (Chrome-style ability on Arc-style data).
  @discardableResult public mutating func detachTab(_ id: TabID) -> WindowID? {
    guard let t = tabs[id], let si = spaceIndex(t.space) else { return nil }
    let idx = spaces[si].tabOrder.firstIndex(of: id) ?? 0
    if let holder = windowShowing(id) { windows[holder]!.selected = neighbour(in: spaces[si].tabOrder, near: idx, for: holder, skip: id) }
    var w = BrowserWindow(space: t.space, selected: id); w.lastSelected[t.space] = id
    windows[w.id] = w; return w.id
  }

  // MARK: invariants
  public func validate() -> [String] {
    var errs: [String] = []
    var seen = Set<TabID>()
    var seenProfiles = Set<ProfileID>()
    for p in profiles {
      if !seenProfiles.insert(p.id).inserted { errs.append("profile \(p.id.raw) listed twice") }
    }
    var seenFolders = Set<FolderID>()
    for s in spaces {
      if profile(s.profile) == nil { errs.append("space \(s.id.raw) references missing profile") }
      for fid in s.folderOrder {
        if !seenFolders.insert(fid).inserted { errs.append("folder \(fid.raw) listed twice") }
        guard let f = folders[fid] else { errs.append("folder \(fid.raw) missing in folders"); continue }
        if f.space != s.id { errs.append("folder \(fid.raw) space mismatch") }
      }
      for t in s.tabOrder {
        if !seen.insert(t).inserted { errs.append("tab \(t.raw) listed twice") }
        if tabs[t]?.space != s.id { errs.append("tab \(t.raw) space mismatch") }
      }
    }
    for (fid, f) in folders {
      if space(f.space) == nil { errs.append("folder \(fid.raw) references missing space") }
      if !seenFolders.contains(fid) { errs.append("folder \(fid.raw) not in space folderOrder") }
    }
    for (tid, t) in tabs {
      if let fid = t.folderId {
        guard let f = folders[fid] else { errs.append("tab \(tid.raw) references missing folder \(fid.raw)"); continue }
        if f.space != t.space { errs.append("tab \(tid.raw) folder space mismatch") }
      }
    }
    for t in tabs.keys where !seen.contains(t) { errs.append("tab \(t.raw) in no space") }
    var archived = Set<TabID>()
    for a in archive {
      if !archived.insert(a.id).inserted { errs.append("tab \(a.id.raw) archived twice") }
      if tabs[a.id] != nil { errs.append("tab \(a.id.raw) both live and archived") }
    }
    var shown = Set<TabID>()
    for w in windows.values {
      for (sp, t) in w.lastSelected where tabs[t] == nil || tabs[t]?.space != sp { errs.append("window lastSelected dangling") }
      guard space(w.space) != nil else { errs.append("window on missing space"); continue }
      if let t = w.selected {
        if tabs[t]?.space != w.space { errs.append("window selects tab outside its space") }
        if !shown.insert(t).inserted { errs.append("tab selected in two windows") }
      }
    }
    return errs
  }
}
