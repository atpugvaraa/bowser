import AppKit
import WebKit

// Throwaway video test browser: persistent login, address bar, optional Safari-style UA,
// logs <video> resolution to ~/Library/Logs/vt-video.log every 5 s.
final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate, WKNavigationDelegate, WKUIDelegate {
  var win: NSWindow!, wv: WKWebView!, addr: NSTextField!
  let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/vt-video.log")

  func applicationDidFinishLaunching(_ n: Notification) {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .default()                       // persistent logins
    if CommandLine.arguments.contains("--safari-ua") {
      cfg.applicationNameForUserAgent = "Version/17.6 Safari/605.1.15"
    }
    cfg.allowsAirPlayForMediaPlayback = true
    wv = WKWebView(frame: .zero, configuration: cfg)
    wv.navigationDelegate = self; wv.uiDelegate = self
    wv.isInspectable = true
    addr = NSTextField(); addr.delegate = self; addr.placeholderString = "URL"
    win = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 800),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "vt"
    let box = NSView(frame: win.contentView!.bounds); box.autoresizingMask = [.width, .height]
    addr.frame = .init(x: 8, y: box.bounds.height - 30, width: box.bounds.width - 16, height: 24); addr.autoresizingMask = [.width, .minYMargin]
    wv.frame = .init(x: 0, y: 0, width: box.bounds.width, height: box.bounds.height - 36); wv.autoresizingMask = [.width, .height]
    box.addSubview(wv); box.addSubview(addr); win.contentView = box
    win.center(); win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let start = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "https://www.netflix.com"
    load(start)
    if let i = CommandLine.arguments.firstIndex(of: "--eval"), i + 1 < CommandLine.arguments.count {
      let js = CommandLine.arguments[i + 1]
      for t in [10.0, 20.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.wv.evaluateJavaScript(js, completionHandler: nil) } }
    }
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.logVideo() }
  }
  func load(_ s: String) {
    let u = URL(string: s.contains("://") ? s : "https://" + s)!
    addr.stringValue = u.absoluteString; wv.load(URLRequest(url: u))
  }
  func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.insertNewline(_:)) { load(addr.stringValue); win.makeFirstResponder(wv); return true }
    return false
  }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { addr.stringValue = w.url?.absoluteString ?? "" }
  func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if a.targetFrame == nil { w.load(a.request) }; return nil   // open popups in same view
  }
  func logVideo() {
    let js = "JSON.stringify([...document.querySelectorAll('video')].map(v=>({w:v.videoWidth,h:v.videoHeight,t:Math.round(v.currentTime),paused:v.paused,dropped:v.getVideoPlaybackQuality?.().droppedVideoFrames,total:v.getVideoPlaybackQuality?.().totalVideoFrames})))"
    wv.evaluateJavaScript(js) { r, _ in
      guard let s = r as? String, s != "[]" else { return }
      let line = "\(Date()) \(self.wv.url?.host ?? "?") \(s)\n"
      if let h = try? FileHandle(forWritingTo: self.logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
      else { try? line.write(to: self.logURL, atomically: true, encoding: .utf8) }
    }
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu(); let mi = NSMenuItem(); menu.addItem(mi)
let sub = NSMenu(); sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); mi.submenu = sub
let em = NSMenuItem(); menu.addItem(em); let es = NSMenu(title: "Edit"); em.submenu = es
for (t, a, k) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
  es.addItem(withTitle: t, action: Selector(a), keyEquivalent: k)
}
app.mainMenu = menu
let d = App(); app.delegate = d
app.run()
