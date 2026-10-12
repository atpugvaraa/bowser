import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
// Dump WebKit's runtime feature flags via private WKPreferences API (research only; read-only).
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
DispatchQueue.main.async {
  let prefs = WKPreferences()
  var rows: [[String: Any]] = []
  for sel in ["_features", "_experimentalFeatures", "_internalDebugFeatures"] {
    guard WKPreferences.responds(to: NSSelectorFromString(sel)) else { print("# \(sel): class method missing"); continue }
    guard let arr = WKPreferences.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? [NSObject] else { print("# \(sel): none"); continue }
    for f in arr {
      let key = f.value(forKey: "key") as? String ?? "?"
      let name = f.value(forKey: "name") as? String ?? "?"
      let status = (f.value(forKey: "status") as? NSNumber)?.intValue ?? -1
      let def = (f.value(forKey: "defaultValue") as? NSNumber)?.boolValue
      let details = f.value(forKey: "details") as? String ?? ""
      let cat = f.value(forKey: "category") as? NSNumber
      var enabled: Bool? = nil
      if prefs.responds(to: NSSelectorFromString("_isEnabledForFeature:")) { enabled = prefs.perform(NSSelectorFromString("_isEnabledForFeature:"), with: f) != nil ? nil : nil }
      rows.append(["set": sel, "key": key, "name": name, "status": status, "default": def as Any, "category": cat as Any, "details": String(details.prefix(110))])
    }
  }
  print("TOTAL \(rows.count)")
  for r in rows { print("\(r["set"]!)\t\(r["status"]!)\t\(r["default"] ?? "?")\t\(r["key"]!)\t\(r["details"]!)") }
  exit(0)
}
app.run()
