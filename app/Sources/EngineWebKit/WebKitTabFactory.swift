import BrowserCore
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
  public init(persistent: Bool = true) { self.persistent = persistent }

  public func configuration(for profile: ProfileID) -> WKWebViewConfiguration {
    if let c = configs[profile] { return c }
    let c = WKWebViewConfiguration()
    c.websiteDataStore = persistent ? WKWebsiteDataStore(forIdentifier: profile.raw) : .nonPersistent()
    // TODO(signed-app phase): enable `WebKitFeatureFlags.set("MediaDevicesEnabled", true, for: c.preferences)` for calls/meetings, ONLY together with
    // NSCameraUsageDescription / NSMicrophoneUsageDescription + entitlements; without them macOS can hang or terminate the app on access.
    configs[profile] = c
    return c
  }

  public func makeTab(id: TabID, url: URL?, profile: ProfileID, restoredState: Data?) -> any EngineTab {
    let t = WebKitTab(id: id, url: url, configuration: configuration(for: profile))
    t.restore(state: restoredState)
    return t
  }
}
