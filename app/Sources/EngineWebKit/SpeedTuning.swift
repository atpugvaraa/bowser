import Foundation
import WebKit

/// Network-speed knobs WebKit keeps private. Every call is guarded (`responds(to:)`), so a future macOS that drops one just loses that speed-up.
public enum SpeedTuning {
  /// A persistent profile store that also turns on speculative cache revalidation (what Safari does: on a repeat visit the subresources
  /// recorded last time are revalidated in parallel instead of waiting for the page to ask for them). Same on-disk location as `WKWebsiteDataStore(forIdentifier:)`.
  @MainActor public static func persistentStore(identifier: UUID, speculativeRevalidation: Bool) -> WKWebsiteDataStore {
    guard speculativeRevalidation,
          let cfgClass = NSClassFromString("_WKWebsiteDataStoreConfiguration") as? NSObject.Type,
          cfgClass.instancesRespond(to: NSSelectorFromString("initWithIdentifier:")),
          let raw = cfgClass.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject,
          let cfg = raw.perform(NSSelectorFromString("initWithIdentifier:"), with: identifier as NSUUID)?.takeUnretainedValue() as? NSObject,
          cfg.responds(to: NSSelectorFromString("setNetworkCacheSpeculativeValidationEnabled:")),
          WKWebsiteDataStore.instancesRespond(to: NSSelectorFromString("_initWithConfiguration:")),
          let rawStore = WKWebsiteDataStore.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject
    else { return WKWebsiteDataStore(forIdentifier: identifier) }
    cfg.setValue(true, forKey: "networkCacheSpeculativeValidationEnabled")
    guard let store = rawStore.perform(NSSelectorFromString("_initWithConfiguration:"), with: cfg)?.takeUnretainedValue() as? WKWebsiteDataStore else { return WKWebsiteDataStore(forIdentifier: identifier) }
    return store
  }

  /// Open a connection (DNS + TCP + TLS) to the page's server before the navigation starts, e.g. while the user is still typing the address.
  @MainActor public static func preconnect(_ url: URL, using view: WKWebView?) {
    guard url.scheme == "https" || url.scheme == "http", let view, view.responds(to: NSSelectorFromString("_preconnectToServer:")) else { return }
    _ = view.perform(NSSelectorFromString("_preconnectToServer:"), with: url as NSURL)
  }
}
