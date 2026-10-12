import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
// Which operation keeps a WKWebView alive after we drop it? Each variant x 15 rounds.
let page = "data:text/html,<html><body><input id=f><script>window.__bdirty=false;addEventListener('input',()=>window.__bdirty=true,true)</script></body></html>"
final class Loader: NSObject, WKNavigationDelegate { var c: CheckedContinuation<Void, Never>?
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { c?.resume(); c = nil } }
final class Box { weak var v: WKWebView? }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
@MainActor func trial(_ name: String, cfg: WKWebViewConfiguration, _ op: (WKWebView) async -> Void) async -> Int {
  var alive = 0
  for _ in 0..<15 {
    let box = Box()
    do {
      let w = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 200), configuration: cfg)
      let l = Loader(); w.navigationDelegate = l
      await withCheckedContinuation { c in l.c = c; w.load(URLRequest(url: URL(string: page)!)) }
      box.v = w
      await op(w)
      w.stopLoading(); w.navigationDelegate = nil
    }
    for _ in 0..<30 { if box.v == nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
    if box.v != nil { alive += 1 }
  }
  print("\(name): \(alive)/15 still alive after 3 s")
  return alive
}
@MainActor func trial2(_ name: String, dirty: Bool, archive: Bool, attach: Bool) async -> Int {
  var alive = 0
  let cfg = WKWebViewConfiguration()
  for _ in 0..<15 {
    let box = Box()
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    do {
      let w = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 200), configuration: cfg)
      let l = Loader(); w.navigationDelegate = l
      if attach { win.contentView = w; win.orderBack(nil) }
      await withCheckedContinuation { c in l.c = c; w.load(URLRequest(url: URL(string: page)!)) }
      box.v = w
      if dirty { _ = try? await w.evaluateJavaScript("document.getElementById('f').dispatchEvent(new Event('input',{bubbles:true})); 0") }
      if archive, let st = w.interactionState { _ = try? NSKeyedArchiver.archivedData(withRootObject: st, requiringSecureCoding: false) }
      w.stopLoading(); w.navigationDelegate = nil
      if attach { win.contentView = NSView() } else { w.removeFromSuperview() }
    }
    for _ in 0..<30 { if box.v == nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
    if box.v != nil { alive += 1 }
  }
  print("\(name): \(alive)/15 still alive after 3 s")
  return alive
}
@MainActor func trial3(_ name: String, signals: Bool, dirty: Bool) async -> Int {
  var alive = 0
  let cfg = WKWebViewConfiguration()
  for _ in 0..<30 {
    let box = Box()
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    do {
      let w = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 200), configuration: cfg)
      let l = Loader(); w.navigationDelegate = l; win.contentView = w; win.orderBack(nil)
      await withCheckedContinuation { c in l.c = c; w.load(URLRequest(url: URL(string: page)!)) }
      box.v = w
      if dirty { _ = try? await w.evaluateJavaScript("document.getElementById('f').dispatchEvent(new Event('input',{bubbles:true})); 0") }
      if signals {
        _ = w.isLoading; _ = w.cameraCaptureState; _ = w.microphoneCaptureState
        _ = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in w.requestMediaPlaybackState { c.resume(returning: $0.rawValue) } }
        _ = try? await w.evaluateJavaScript("window.__bdirty === true")
      }
      if let st = w.interactionState { _ = try? NSKeyedArchiver.archivedData(withRootObject: st, requiringSecureCoding: false) }
      w.stopLoading(); w.navigationDelegate = nil; win.contentView = NSView()
    }
    for _ in 0..<150 { if box.v == nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
    if box.v != nil { alive += 1 }
  }
  print("\(name): \(alive)/30 still alive after 15 s")
  return alive
}
Task { @MainActor in
  _ = await trial3("signals+dirty (tab-0 recipe) ", signals: true, dirty: true)
  _ = await trial3("signals only                 ", signals: true, dirty: false)
  _ = await trial3("neither                      ", signals: false, dirty: false)
  exit(0)
}
Task { @MainActor in
  _ = await trial2("window, no dirty, no archive ", dirty: false, archive: false, attach: true)
  _ = await trial2("window, dirty, no archive    ", dirty: true, archive: false, attach: true)
  _ = await trial2("window, no dirty, archive    ", dirty: false, archive: true, attach: true)
  _ = await trial2("window, dirty, archive       ", dirty: true, archive: true, attach: true)
  let cfg = WKWebViewConfiguration()
  _ = await trial("none                     ", cfg: cfg) { _ in }
  _ = await trial("evaluateJavaScript       ", cfg: cfg) { w in _ = try? await w.evaluateJavaScript("1+1") }
  _ = await trial("dispatch input event     ", cfg: cfg) { w in _ = try? await w.evaluateJavaScript("document.getElementById('f').dispatchEvent(new Event('input',{bubbles:true})); 0") }
  _ = await trial("requestMediaPlaybackState", cfg: cfg) { w in _ = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in w.requestMediaPlaybackState { c.resume(returning: $0.rawValue) } } }
  _ = await trial("cameraCaptureState read  ", cfg: cfg) { w in _ = w.cameraCaptureState }
  _ = await trial("interactionState read    ", cfg: cfg) { w in _ = w.interactionState }
  _ = await trial("all of the above         ", cfg: cfg) { w in
    _ = try? await w.evaluateJavaScript("document.getElementById('f').dispatchEvent(new Event('input',{bubbles:true})); 0")
    _ = await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in w.requestMediaPlaybackState { c.resume(returning: $0.rawValue) } }
    _ = w.interactionState; _ = w.cameraCaptureState }
  exit(0)
}
app.run()
