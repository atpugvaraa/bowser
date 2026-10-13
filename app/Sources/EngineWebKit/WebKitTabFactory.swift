import BrowserCore
import ContentBlocking
import EngineCore
import Foundation
import AppKit
import IOKit.ps
import WebKit

/// Builds WebKit tabs. One WKWebViewConfiguration (and therefore one data store: cookies, logins, storage) per profile, shared by
/// all that profile's tabs, so hibernating/restoring a tab never touches the user's sessions. Per-profile isolation uses
/// WKWebsiteDataStore(forIdentifier:), verified in spikes/profile-test. `persistent: false` is for tests (leaves nothing on disk).
@MainActor
public final class WebKitTabFactory: TabFactory {
  private var configs: [ProfileID: WKWebViewConfiguration] = [:]
  private let persistent: Bool
  public var linkOpenHandler: ((_ from: TabID, _ url: URL) -> Void)?
  /// A page that was opened by script asked to close itself.
  public var closeRequestHandler: ((TabID) -> Void)?
  /// A user click on mailto:/tel:/app links (the UI hands it to the system).
  public var externalOpenHandler: ((URL) -> Void)?
  public let downloads: DownloadCoordinator
  // Content blocking: the compiled list is added to every profile configuration SYNCHRONOUSLY when it is created, so the very
  // first request of a page is already covered (prepare it before creating any tab).
  private var blockingList: WKContentRuleList?
  public private(set) var blockingActive = false
  /// Compile and activate (or deactivate) blocking. Safe to call at launch and when the user flips the setting.
  public func prepareContentBlocking(_ settings: BlockingSettings, storeURL: URL) async throws {
    if settings.enabled {
      let blocker = try ContentBlocker(storeURL: storeURL)
      blockingList = try await blocker.compile(id: "builtin", blockRules: BuiltInBlocklist.rules, allowlistDomains: settings.effectiveAllowlist)
    } else { blockingList = nil }
    blockingActive = blockingList != nil
    for c in configs.values {                                  // existing profiles: swap the list (affects page loads from now on)
      c.userContentController.removeAllContentRuleLists()
      if let l = blockingList { c.userContentController.add(l) }
    }
  }
  public init(persistent: Bool = true, downloads: DownloadCoordinator = DownloadCoordinator()) { self.persistent = persistent; self.downloads = downloads }

  // Adaptive frame rate (FrameGovernor). The ceiling follows power state; changes are pushed to live pages and to every future page load.
  private var governor = FrameGovernor.forCurrentPower()
  private let liveTabs = NSHashTable<WebKitTab>.weakObjects()
  private var powerSource: CFRunLoopSource?
  public func startPowerWatch() {
    guard powerSource == nil else { return }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    if let src = IOPSNotificationCreateRunLoopSource({ p in guard let p else { return }; let f = Unmanaged<WebKitTabFactory>.fromOpaque(p).takeUnretainedValue(); MainActor.assumeIsolated { f.refreshGovernor() } }, ctx)?.takeRetainedValue() {
      CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); powerSource = src
    }
    for n in [Notification.Name.NSProcessInfoPowerStateDidChange, Notification.Name("NSApplicationDidChangeScreenParametersNotification")] {
      NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshGovernor() } }
    }
  }
  func refreshGovernor() {
    let g = FrameGovernor.forCurrentPower()
    guard g != governor else { return }
    governor = g
    for c in configs.values {                                   // future page loads (this also re-adds the shared scripts, which are installed per controller)
      c.userContentController.removeAllUserScripts()
      c.userContentController.addUserScript(WebKitTab.dirtyScript); c.userContentController.addUserScript(WebKitTab.connScript)
      c.userContentController.addUserScript(WKUserScript(source: g.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    for t in liveTabs.allObjects { t.webView?.evaluateJavaScript(g.updateJS, completionHandler: nil) }
  }

  public func configuration(for profile: ProfileID) -> WKWebViewConfiguration {
    if let c = configs[profile] { return c }
    let c = WKWebViewConfiguration()
    c.websiteDataStore = persistent ? WKWebsiteDataStore(forIdentifier: profile.raw) : .nonPersistent()
    // TODO(signed-app phase): enable `WebKitFeatureFlags.set("MediaDevicesEnabled", true, for: c.preferences)` for calls/meetings, ONLY together with
    // NSCameraUsageDescription / NSMicrophoneUsageDescription + entitlements; without them macOS can hang or terminate the app on access.
    if governor.enabled && (NSScreen.main?.maximumFramesPerSecond ?? 60) > 60 {                 // WebKit caps pages near 60 fps unless told not to; the governor owns the ceiling instead
      WebKitFeatureFlags.set("PreferPageRenderingUpdatesNear60FPSEnabled", false, for: c.preferences)
    }
    if governor.enabled { c.userContentController.addUserScript(WKUserScript(source: governor.source, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
    c.preferences.isElementFullscreenEnabled = true              // the player's fullscreen button (YouTube, Netflix, Prime) does nothing without this
    if let l = blockingList { c.userContentController.add(l) }
    configs[profile] = c
    return c
  }

  public func makeTab(id: TabID, url: URL?, profile: ProfileID, restoredState: Data?) -> any EngineTab {
    let t = WebKitTab(id: id, url: url, configuration: configuration(for: profile))
    t.restore(state: restoredState); liveTabs.add(t)
    t.onOpenURL = { [weak self] u in self?.linkOpenHandler?(id, u) }
    t.onOpenExternally = { [weak self] u in self?.externalOpenHandler?(u) }
    t.onDownload = { [weak self] d in self?.downloads.adopt(d) }
    t.onPageRequestedClose = { [weak self] in self?.closeRequestHandler?(id) }
    return t
  }
}
