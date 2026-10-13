import BrowserCore
import Extensions
import AppKit
import Foundation
import WebKit

/// What the extension engine needs to know about the browser's windows and tabs. Implemented by the app (BrowserEngine owns the truth).
@MainActor
public protocol ExtensionEnvironment: AnyObject {
  func windowIDs() -> [WindowID]
  func focusedWindow() -> WindowID?
  func tabs(in window: WindowID) -> [WebKitTab]
  func selectedTab(in window: WindowID) -> WebKitTab?
  func window(of tab: TabID) -> WindowID?
  func openTab(url: URL?, active: Bool, in window: WindowID?) -> WebKitTab?
  func select(_ tab: TabID)
  func close(_ tab: TabID)
  func profile(ofWindow window: WindowID) -> ProfileID?
}

/// Installed extensions and their live WebKit contexts. One WKWebExtensionController per profile (extension storage and cookies stay per profile);
/// every installed, enabled extension is loaded into each controller. Permissions are explicit: only what the user granted is given.
@MainActor
public final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
  public struct Record: Codable, Equatable, Sendable {
    public var id: String, name: String, version: String, path: String
    public var enabled = true
    public var permissions: [String] = []        // granted API permissions
    public var hosts: [String] = []              // granted host match patterns
    public var firefox = false
  }
  public private(set) var records: [Record] = []
  public weak var environment: ExtensionEnvironment?
  private let registryURL: URL
  private var controllers: [ProfileID: WKWebExtensionController] = [:]
  private var contexts: [String: [ProfileID: WKWebExtensionContext]] = [:]
  private var tabAdapters: [TabID: TabAdapter] = [:]
  private var windowAdapters: [WindowID: WindowAdapter] = [:]
  /// Sites no extension may touch, whatever it asked for or was granted (account/security pages). Subdomains included. UserDefaults `extensionBlockedSites` replaces the default list.
  public var blockedSites: [String] = UserDefaults.standard.stringArray(forKey: "extensionBlockedSites") ?? ["appleid.apple.com", "idmsa.apple.com", "account.apple.com", "icloud.com", "passwords.apple.com"] {
    didSet { for byProfile in contexts.values { for c in byProfile.values { applyBlocklist(c) } } }
  }
  private func applyBlocklist(_ ctx: WKWebExtensionContext) {
    for raw in blockedSites {
      let h = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
      guard !h.isEmpty, !h.contains("/"), !h.contains("*") else { continue }
      for pat in ["*://\(h)/*", "*://*.\(h)/*", "*://\(h)./*", "*://*.\(h)./*"] { if let m = try? WKWebExtension.MatchPattern(string: pat) { ctx.setPermissionStatus(.deniedExplicitly, for: m) } }
    }
  }
  public private(set) var loadErrors: [String: String] = [:]      // extension id -> last load problem, shown in the UI
  public var persistent = true
  /// Tests use non-persistent (private) data stores; WebKit keeps extensions out of private browsing unless told otherwise.
  public var allowPrivate = false

  public init(registry: URL) {
    registryURL = registry; super.init()
    if let d = try? Data(contentsOf: registry), let r = try? JSONDecoder().decode([Record].self, from: d) { records = r }
  }

  // MARK: registry
  private func save() { if let d = try? JSONEncoder().encode(records) { try? FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true); try? d.write(to: registryURL, options: .atomic) } }

  /// Records a prepared package with exactly the permissions the user approved, and loads it everywhere.
  @discardableResult public func install(_ p: ExtensionPackage.Prepared, permissions: [String], hosts: [String]) async -> Record {
    let r = Record(id: p.id, name: p.name, version: p.version, path: p.directory.path, enabled: true, permissions: permissions, hosts: hosts, firefox: p.isFirefox)
    if let i = records.firstIndex(where: { $0.id == p.id }) { unloadEverywhere(records[i].id); records[i] = r } else { records.append(r) }
    save(); await loadEverywhere(r); return r
  }
  /// Unloads and forgets the registration. Files stay on disk (nothing is ever deleted).
  public func uninstall(_ id: String) { unloadEverywhere(id); records.removeAll { $0.id == id }; save() }
  public func setEnabled(_ id: String, _ on: Bool) async {
    guard let i = records.firstIndex(where: { $0.id == id }) else { return }
    records[i].enabled = on; save()
    if on { await loadEverywhere(records[i]) } else { unloadEverywhere(id) }
  }

  // MARK: controllers
  /// The controller for a profile's web views; created on first use and loaded with all enabled extensions.
  public func controller(for profile: ProfileID, store: WKWebsiteDataStore) -> WKWebExtensionController {
    if let c = controllers[profile] { return c }
    let cfg = persistent ? WKWebExtensionController.Configuration(identifier: profile.raw) : WKWebExtensionController.Configuration.nonPersistent()
    cfg.defaultWebsiteDataStore = store                       // the profile's own cookies/storage: pages in it are NOT private, so extensions run there
    let c = WKWebExtensionController(configuration: cfg)
    c.delegate = self; controllers[profile] = c
    Task { for r in records where r.enabled { await load(r, into: profile) } }
    return c
  }
  private func loadEverywhere(_ r: Record) async { for p in controllers.keys { await load(r, into: p) } }
  private func unloadEverywhere(_ id: String) {
    for (p, ctx) in contexts[id] ?? [:] { try? controllers[p]?.unload(ctx) }
    contexts[id] = nil; loadErrors[id] = nil
  }
  private func load(_ r: Record, into profile: ProfileID) async {
    guard let c = controllers[profile], contexts[r.id]?[profile] == nil else { return }
    do {
      let ext = try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: r.path))
      let ctx = WKWebExtensionContext(for: ext)
      let granted = Set(r.permissions)
      for perm in ext.requestedPermissions { ctx.setPermissionStatus(granted.contains(perm.rawValue) ? .grantedExplicitly : .deniedExplicitly, for: perm) }
      for pat in ext.requestedPermissionMatchPatterns.union(ext.optionalPermissionMatchPatterns) {
        ctx.setPermissionStatus(r.hosts.contains(pat.string) ? .grantedExplicitly : .deniedExplicitly, for: pat)
      }
      applyBlocklist(ctx)
      ctx.hasAccessToPrivateData = allowPrivate
      try c.load(ctx)
      contexts[r.id, default: [:]][profile] = ctx; loadErrors[r.id] = nil
      for e in ext.errors { loadErrors[r.id] = e.localizedDescription }
    } catch { loadErrors[r.id] = "\(error)" }
  }

  /// One line per loaded extension context: for diagnostics and the extensions page.
  public func status() -> [String] {
    contexts.flatMap { id, byProfile in byProfile.values.map { c in
      "\(id): loaded=\(c.isLoaded) injected=\(c.hasInjectedContent) allURLs=\(c.hasAccessToAllURLs) granted=\(c.currentPermissions.map(\.rawValue).sorted()) hostsGranted=\(c.grantedPermissionMatchPatterns.keys.map(\.string).sorted()) denied=\(c.deniedPermissionMatchPatterns.keys.map(\.string).sorted()) errors=\(c.errors.map(\.localizedDescription))" } }
  }

  // MARK: events from the browser
  public func didOpen(_ t: WebKitTab, profile: ProfileID) { controllers[profile]?.didOpenTab(adapter(t)) }
  public func didActivate(_ t: WebKitTab, previous: WebKitTab?, profile: ProfileID) { controllers[profile]?.didActivateTab(adapter(t), previousActiveTab: previous.map { adapter($0) }) }
  public func didClose(_ id: TabID, profile: ProfileID, windowClosing: Bool) { if let a = tabAdapters[id] { controllers[profile]?.didCloseTab(a, windowIsClosing: windowClosing); tabAdapters[id] = nil } }
  public func didChange(_ t: WebKitTab, profile: ProfileID) { controllers[profile]?.didChangeTabProperties([.URL, .title, .loading], for: adapter(t)) }
  public func didOpen(window: WindowID, profile: ProfileID) { controllers[profile]?.didOpenWindow(windowAdapter(window)) }
  public func didFocus(window: WindowID, profile: ProfileID) { controllers[profile]?.didFocusWindow(windowAdapter(window)) }

  fileprivate func adapter(_ t: WebKitTab) -> TabAdapter { if let a = tabAdapters[t.id] { return a }; let a = TabAdapter(t, host: self); tabAdapters[t.id] = a; return a }
  fileprivate func windowAdapter(_ id: WindowID) -> WindowAdapter { if let a = windowAdapters[id] { return a }; let a = WindowAdapter(id, host: self); windowAdapters[id] = a; return a }

  // MARK: toolbar actions
  /// The UI shows the popover it is handed. Set by the app.
  public var presentPopup: ((NSPopover) -> Void)?
  /// Clicks an extension's toolbar button for a tab (opens its popup, or fires its `action.onClicked`).
  public func performAction(_ id: String, tab: WebKitTab?, profile: ProfileID) {
    guard let ctx = contexts[id]?[profile] else { return }
    ctx.performAction(for: tab.map { adapter($0) })
  }
  public func hasContext(_ id: String, profile: ProfileID) -> Bool { contexts[id]?[profile] != nil }

  // MARK: WKWebExtensionControllerDelegate
  public func webExtensionController(_ c: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for ctx: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    if let p = action.popupPopover { presentPopup?(p); completionHandler(nil) } else { completionHandler(NSError(domain: "ExtensionHost", code: 2)) }
  }
  public func webExtensionController(_ c: WKWebExtensionController, openWindowsFor ctx: WKWebExtensionContext) -> [any WKWebExtensionWindow] { windows(for: c).map { windowAdapter($0) } }
  public func webExtensionController(_ c: WKWebExtensionController, focusedWindowFor ctx: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { environment?.focusedWindow().flatMap { w in windows(for: c).contains(w) ? w : nil }.map { windowAdapter($0) } }
  public func webExtensionController(_ c: WKWebExtensionController, openNewTabUsing options: WKWebExtension.TabConfiguration, for ctx: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
    let win = (options.window as? WindowAdapter)?.id
    guard let t = environment?.openTab(url: options.url, active: options.shouldBeActive, in: win) else { completionHandler(nil, NSError(domain: "ExtensionHost", code: 1)); return }
    completionHandler(adapter(t), nil)
  }

  /// Only the windows of the profile this controller belongs to: an extension must not see (or reach the web views of) another profile.
  private func windows(for c: WKWebExtensionController) -> [WindowID] {
    guard let p = controllers.first(where: { $0.value === c })?.key else { return [] }
    return (environment?.windowIDs() ?? []).filter { environment?.profile(ofWindow: $0) == p }
  }
  public func record(_ id: String) -> Record? { records.first { $0.id == id } }

  // MARK: adapters
  final class TabAdapter: NSObject, WKWebExtensionTab {
    weak var tab: WebKitTab?; unowned let host: ExtensionHost
    init(_ t: WebKitTab, host: ExtensionHost) { tab = t; self.host = host }
    func webView(for c: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func window(for c: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { tab.flatMap { host.environment?.window(of: $0.id) }.map { host.windowAdapter($0) } }
    func url(for c: WKWebExtensionContext) -> URL? { tab?.url }
    func title(for c: WKWebExtensionContext) -> String? { tab?.title }
    func isSelected(for c: WKWebExtensionContext) -> Bool { tab?.isActive ?? false }
    func isLoadingComplete(for c: WKWebExtensionContext) -> Bool { !(tab?.isLoadingPage ?? false) }
    func indexInWindow(for c: WKWebExtensionContext) -> Int { guard let t = tab, let w = host.environment?.window(of: t.id) else { return 0 }; return host.environment?.tabs(in: w).firstIndex { $0 === t } ?? 0 }
    func activate(for c: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { if let t = tab { host.environment?.select(t.id) }; completionHandler(nil) }
    func close(for c: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { if let t = tab { host.environment?.close(t.id) }; completionHandler(nil) }
  }
  final class WindowAdapter: NSObject, WKWebExtensionWindow {
    let id: WindowID; unowned let host: ExtensionHost
    init(_ id: WindowID, host: ExtensionHost) { self.id = id; self.host = host }
    func tabs(for c: WKWebExtensionContext) -> [any WKWebExtensionTab] { (host.environment?.tabs(in: id) ?? []).map { host.adapter($0) } }
    func activeTab(for c: WKWebExtensionContext) -> (any WKWebExtensionTab)? { host.environment?.selectedTab(in: id).map { host.adapter($0) } }
    func windowType(for c: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for c: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for c: WKWebExtensionContext) -> Bool { false }
  }
}
