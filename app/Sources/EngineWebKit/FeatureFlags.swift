import Foundation
import WebKit

/// WebKit runtime feature flags (private `WKPreferences._features`, guarded). Embedders need some switched on that Safari enables
/// internally (e.g. MediaDevicesEnabled for getUserMedia). Returns false if the flag/API is unavailable on this macOS.
public enum WebKitFeatureFlags {
  @MainActor @discardableResult public static func set(_ key: String, _ on: Bool, for prefs: WKPreferences) -> Bool {
    guard WKPreferences.responds(to: NSSelectorFromString("_features")),
          let list = WKPreferences.perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject],
          let f = list.first(where: { ($0.value(forKey: "key") as? String) == key }) else { return false }
    let sel = NSSelectorFromString("_setEnabled:forFeature:")
    guard prefs.responds(to: sel), let imp = prefs.method(for: sel) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    unsafeBitCast(imp, to: Fn.self)(prefs, sel, on, f)
    return true
  }
}
