import BrowserCore
import ContentBlocking
import EngineCore
import Foundation
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

  public func configuration(for profile: ProfileID) -> WKWebViewConfiguration {
    if let c = configs[profile] { return c }
    let c = WKWebViewConfiguration()
    c.websiteDataStore = persistent ? WKWebsiteDataStore(forIdentifier: profile.raw) : .nonPersistent()
    // TODO(signed-app phase): enable `WebKitFeatureFlags.set("MediaDevicesEnabled", true, for: c.preferences)` for calls/meetings, ONLY together with
    // NSCameraUsageDescription / NSMicrophoneUsageDescription + entitlements; without them macOS can hang or terminate the app on access.
    c.preferences.isElementFullscreenEnabled = true              // the player's fullscreen button (YouTube, Netflix, Prime) does nothing without this
    if let l = blockingList { c.userContentController.add(l) }
    configs[profile] = c
    return c
  }

  public func makeTab(id: TabID, url: URL?, profile: ProfileID, restoredState: Data?) -> any EngineTab {
    let t = WebKitTab(id: id, url: url, configuration: configuration(for: profile))
    t.restore(state: restoredState)
    t.onOpenURL = { [weak self] u in self?.linkOpenHandler?(id, u) }
    t.onOpenExternally = { [weak self] u in self?.externalOpenHandler?(u) }
    t.onDownload = { [weak self] d in self?.downloads.adopt(d) }
    t.onPageRequestedClose = { [weak self] in self?.closeRequestHandler?(id) }
    return t
  }
}
