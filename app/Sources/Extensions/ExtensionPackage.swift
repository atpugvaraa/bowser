import CryptoKit
import Foundation

/// Turns a Chrome or Firefox extension (folder, .zip, .crx, .xpi) into a plain unpacked folder the WebKit extension engine can load,
/// and rewrites its manifest where Firefox/MV2 conventions differ from what WebKit accepts. Pure Foundation: no WebKit, no UI.
/// Nothing is ever deleted: a package is unpacked into `<root>/<id>/<version>/` and its original is kept beside it.
public enum ExtensionPackage {
  public enum PackageError: Error, Equatable {
    case notFound, badCRX(String), unsafeEntry(String), unzipFailed(Int32), noManifest, badManifest(String), tooLarge(String)
  }
  public struct Prepared: Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var directory: URL
    public var isFirefox: Bool
    public var notes: [String]          // what was rewritten or is unsupported; shown to the user at install time
    public var permissions: [String]    // API permissions requested (not host patterns)
    public var hostPatterns: [String]
  }

  /// API permissions WebKit's extension engine lacks natively; the shim layer fills these in (or the extension is told clearly).
  public static let needsShim: Set<String> = ["downloads", "history", "bookmarks", "offscreen", "userScripts", "nativeMessaging", "webRequestBlocking", "webRequest", "contextMenus", "commands", "proxy", "tabGroups"]

  // MARK: install
  public static let maxPackageBytes = 200 << 20, maxUnpackedBytes = 500 << 20, maxEntries = 10_000, maxManifestBytes = 1 << 20

  public static func prepare(source: URL, into root: URL) throws -> Prepared {
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw PackageError.notFound }
    var unpacked = source
    var hash = ""
    if !isDir.boolValue {
      let size = ((try? fm.attributesOfItem(atPath: source.path))?[.size] as? Int) ?? 0
      guard size <= maxPackageBytes else { throw PackageError.tooLarge("package is \(size >> 20) MB") }
      var data = try Data(contentsOf: source)
      hash = digest(data)
      if data.starts(with: Array("Cr24".utf8)) { data = try zipData(fromCRX: data) }
      let stage = root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(hash, isDirectory: true)
      try fm.createDirectory(at: stage, withIntermediateDirectories: true)
      let zip = stage.appendingPathComponent("package.zip")
      try data.write(to: zip, options: .atomic)
      unpacked = stage.appendingPathComponent("files", isDirectory: true)
      if !fm.fileExists(atPath: unpacked.appendingPathComponent("manifest.json").path) {
        let tmp = stage.appendingPathComponent("files.tmp-\(UUID().uuidString)", isDirectory: true)       // a killed/failed unzip never leaves a "complete-looking" folder
        try unzip(zip, into: tmp)
        try fm.moveItem(at: tmp, to: unpacked)
      }
    }
    try rejectSymlinks(in: unpacked)
    if isDir.boolValue { hash = try treeDigest(unpacked) }
    let manifestURL = unpacked.appendingPathComponent("manifest.json")
    guard let attrs = try? fm.attributesOfItem(atPath: manifestURL.path) else { throw PackageError.noManifest }
    guard ((attrs[.size] as? Int) ?? 0) <= maxManifestBytes else { throw PackageError.tooLarge("manifest.json") }
    guard let raw = try? Data(contentsOf: manifestURL) else { throw PackageError.noManifest }
    guard var m = (try? JSONSerialization.jsonObject(with: stripBOM(raw))) as? [String: Any] else { throw PackageError.badManifest("not a JSON object") }
    let n = normalize(&m)
    guard let name = m["name"] as? String, let version = m["version"] as? String else { throw PackageError.badManifest("missing name or version") }
    let mv = (m["manifest_version"] as? Int) ?? 2
    let id = n.geckoID ?? "ext-" + String(digest(Data(((m["key"] as? String) ?? name).utf8)).prefix(16))      // stable across versions so updates replace, never collide by code
    // The folder name carries the package's content hash: two different packages can never share (or merge into) a folder, and a re-install of identical bytes is a no-op.
    let dest = root.appendingPathComponent(safeComponent(id), isDirectory: true).appendingPathComponent(safeComponent(version) + "-" + hash.prefix(12), isDirectory: true)
    if !fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) {
      let tmp = dest.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: unpacked, to: tmp)
      try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: tmp.appendingPathComponent("manifest.json"), options: .atomic)
      try fm.moveItem(at: tmp, to: dest)
    }
    let perms = ((m["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }
    let hosts = ((m["host_permissions"] as? [Any]) ?? []).compactMap { $0 as? String } + perms.filter(isHostPattern)
    return Prepared(id: id, name: name, version: version, manifestVersion: mv, directory: dest, isFirefox: n.geckoID != nil || n.firefoxKeys,
                    notes: n.notes, permissions: perms.filter { !isHostPattern($0) }, hostPatterns: hosts)
  }

  // MARK: manifest normalisation
  /// Rewrites `m` in place. Idempotent.
  @discardableResult public static func normalize(_ m: inout [String: Any]) -> (geckoID: String?, firefoxKeys: Bool, notes: [String]) {
    var notes: [String] = []
    var gecko: String?
    var ff = false
    for key in ["browser_specific_settings", "applications"] {
      guard let bs = m[key] as? [String: Any] else { continue }
      ff = true
      if let g = bs["gecko"] as? [String: Any], let id = g["id"] as? String, gecko == nil { gecko = id }
      m[key] = nil
    }
    if ff { notes.append("Firefox extension: Gecko-specific settings were ignored.") }
    let mv = (m["manifest_version"] as? Int) ?? 2
    if var bg = m["background"] as? [String: Any] {
      if mv == 2, bg["persistent"] as? Bool != false {
        bg["persistent"] = false
        notes.append("MV2 persistent background converted to an event page (it sleeps when idle; saves power). Extensions that keep state in memory may misbehave.")
      }
      if mv == 3, bg["service_worker"] != nil, bg["scripts"] != nil {     // Chrome and Firefox both accept this form; WebKit wants one
        bg["scripts"] = nil
        notes.append("Both service_worker and scripts were declared; using the service worker.")
      }
      m["background"] = bg
    }
    if ((m["description"] as? String) ?? "").isEmpty { m["description"] = (m["name"] as? String) ?? "Extension" }    // WebKit flags a missing description as an error
    if m["chrome_url_overrides"] != nil { notes.append("Replaces a browser page (new tab / history): not supported yet, ignored.") }
    if m["update_url"] != nil { m["update_url"] = nil; notes.append("Auto-update from the original store is disabled.") }
    let perms = ((m["permissions"] as? [Any]) ?? []).compactMap { $0 as? String } + ((m["optional_permissions"] as? [Any]) ?? []).compactMap { $0 as? String }
    let missing = perms.filter { needsShim.contains($0) }.sorted()
    if !missing.isEmpty { notes.append("Uses APIs WebKit does not provide natively (\(Set(missing).sorted().joined(separator: ", "))); the compatibility layer supplies those it can.") }
    return (gecko, ff, notes)
  }

  public static func isHostPattern(_ s: String) -> Bool { s == "<all_urls>" || s.contains("://") || s.hasPrefix("*:") }

  // MARK: CRX / zip
  /// Strips the CRX2/CRX3 header and returns the zip payload.
  public static func zipData(fromCRX d: Data) throws -> Data {
    func u32(_ at: Int) -> Int? { d.count >= at + 4 ? Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24 : nil }
    guard d.count > 12, d.starts(with: Array("Cr24".utf8)), let ver = u32(4) else { throw PackageError.badCRX("not a CRX") }
    let start: Int
    switch ver {
    case 2: guard let pk = u32(8), let sig = u32(12) else { throw PackageError.badCRX("short header") }; start = 16 + pk + sig
    case 3: guard let hl = u32(8) else { throw PackageError.badCRX("short header") }; start = 12 + hl
    default: throw PackageError.badCRX("unknown CRX version \(ver)")
    }
    guard start > 0, start < d.count, d[start...].starts(with: [0x50, 0x4B]) else { throw PackageError.badCRX("no zip after header") }
    return d.subdata(in: start..<d.count)
  }

  /// Unzips with the system `unzip` after checking every entry (no absolute paths, no `..`, no symlinks, bounded count and size).
  static func unzip(_ zip: URL, into dest: URL) throws {
    let names = try run("/usr/bin/unzip", ["-Z1", zip.path])
    let entries = names.out.split(separator: "\n")
    guard entries.count <= maxEntries else { throw PackageError.tooLarge("\(entries.count) entries") }
    for line in entries {
      let e = String(line)
      if e.hasPrefix("/") || e.split(separator: "/").contains("..") || e.contains("\0") { throw PackageError.unsafeEntry(e) }
    }
    let long = try run("/usr/bin/unzip", ["-Z", zip.path])                      // long listing: first column of each entry line starts with the type (l = symlink)
    if long.out.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) { throw PackageError.unsafeEntry("symbolic link inside the package") }
    let summary = try run("/usr/bin/unzip", ["-Zt", zip.path]).out                // "N files, X bytes uncompressed, ..."
    if let r = summary.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression), let total = Int(summary[r].split(separator: " ")[0]), total > maxUnpackedBytes { throw PackageError.tooLarge("\(total >> 20) MB unpacked") }
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let r = try run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", dest.path])
    guard r.status == 0 else { throw PackageError.unzipFailed(r.status) }
    try rejectSymlinks(in: dest)
    // zips made on other systems sometimes wrap everything in one top folder: hoist it
    if !FileManager.default.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) {
      let kids = (try? FileManager.default.contentsOfDirectory(atPath: dest.path).filter { !$0.hasPrefix("__MACOSX") && !$0.hasPrefix(".") }) ?? []
      if kids.count == 1, FileManager.default.fileExists(atPath: dest.appendingPathComponent(kids[0]).appendingPathComponent("manifest.json").path) {
        try copyTree(from: dest.appendingPathComponent(kids[0]), to: dest)
      }
    }
  }

  /// Any symbolic link anywhere in an unpacked extension is refused (it could point at the user's files or let later entries escape the folder).
  static func rejectSymlinks(in dir: URL) throws {
    guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
    var count = 0
    for case let u as URL in en {
      count += 1; if count > maxEntries { throw PackageError.tooLarge("\(count) files") }
      if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw PackageError.unsafeEntry("symbolic link: \(u.lastPathComponent)") }
    }
  }
  /// Content hash of a folder (paths + bytes, sorted) so an edited unpacked extension is a new version, not a silent overwrite.
  static func treeDigest(_ dir: URL) throws -> String {
    var h = SHA256(); var total = 0
    guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return "" }
    var files: [URL] = []
    for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(u) }
    for u in files.sorted(by: { $0.path < $1.path }) {
      total += (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      if total > maxUnpackedBytes { throw PackageError.tooLarge("folder") }
      h.update(data: Data(String(u.path.dropFirst(dir.path.count)).utf8)); h.update(data: try Data(contentsOf: u))
    }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func copyTree(from: URL, to: URL) throws {
    let fm = FileManager.default
    for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
      let target = to.appendingPathComponent(item.lastPathComponent)
      if fm.fileExists(atPath: target.path) { var d: ObjCBool = false; fm.fileExists(atPath: item.path, isDirectory: &d); if d.boolValue { try copyTree(from: item, to: target) }; continue }
      try fm.copyItem(at: item, to: target)
    }
  }

  static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run()
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }; DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }
  static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
  static func stripBOM(_ d: Data) -> Data { d.starts(with: [0xEF, 0xBB, 0xBF]) ? d.dropFirst(3) : d }
  static func safeComponent(_ s: String) -> String {
    let t = String(s.map { $0.isLetter || $0.isNumber || "._-@".contains($0) ? $0 : "_" }).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return t.isEmpty ? "_" : t
  }
}
