import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
let url = URL(string: "http://127.0.0.1:8767/")!
let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
final class Loader: NSObject, WKNavigationDelegate {
  var cont: CheckedContinuation<Void, Never>?
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { cont?.resume(); cont = nil }
}
@MainActor func read(_ store: WKWebsiteDataStore, write: String? = nil) async -> String {
  let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = store
  let wv = WKWebView(frame: .zero, configuration: cfg); let l = Loader(); wv.navigationDelegate = l
  await withCheckedContinuation { c in l.cont = c; wv.load(URLRequest(url: url)) }
  if let w = write { _ = try? await wv.evaluateJavaScript("document.cookie='k=\(w); max-age=86400'; localStorage.setItem('k','\(w)'); indexedDB.open('d'+'\(w)'); 0") }
  let r = try? await wv.evaluateJavaScript("'cookie=['+document.cookie+'] ls=['+localStorage.getItem('k')+']'")
  return (r as? String) ?? "?"
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
Task { @MainActor in
  let a = WKWebsiteDataStore(forIdentifier: idA), b = WKWebsiteDataStore(forIdentifier: idB)
  let first = CommandLine.arguments.contains("--first")
  if first {
    print("A initial       :", await read(a))
    print("A write 'A'     :", await read(a, write: "A"))
    print("B initial       :", await read(b))
    print("B write 'B'     :", await read(b, write: "B"))
    print("default initial :", await read(.default()))
  }
  print("A re-read       :", await read(a))
  print("B re-read       :", await read(b))
  print("default re-read :", await read(.default()))
  print("known ids       :", await WKWebsiteDataStore.allDataStoreIdentifiers.map(\.uuidString))
  exit(0)
}
app.run()
