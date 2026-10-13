import AppKit
import BrowserCore
import EngineWebKit
import Extensions
import Foundation
import WebKit

// ExtLab: load one extension into a real WebKit tab, open a URL, run JS, print what happened. Dev tool for the compatibility matrix.
// usage: ExtLab <dir|file|chrome:ID|firefox:SLUG> <url> <seconds> [--eval <js>] [--grant-optional]
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments

// --bench <url> [--plain] [--no-governor]: cold load timing of one page in a fresh process, product configuration vs a bare WKWebView.
if args.count >= 3, args[1] == "bench" {
  let benchApp = NSApplication.shared; benchApp.setActivationPolicy(.accessory)
  let plain = args.contains("--plain")
  if args.contains("--no-governor") { UserDefaults.standard.set("off", forKey: "frameGovernor") }
  Task { @MainActor in
    let w: WKWebView
    var keep: Any?
    if plain {
      let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); if !args.contains("--legacy") { c.applicationNameForUserAgent = "Version/27.0.1 Safari/605.1.15" }
      let with = args.firstIndex(of: "--with").map { args[$0 + 1] } ?? ""
      if with.contains("gov") { c.userContentController.addUserScript(WKUserScript(source: FrameGovernor(maxHz: 120).source, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
      if with.contains("pk") { c.userContentController.addUserScript(PasskeyBridge.script()) }
      if with.contains("pkh") { let b = PasskeyBridge(); c.userContentController.addScriptMessageHandler(b, contentWorld: .page, name: "bpasskey"); keep = b }
      if with.contains("fs") { c.preferences.isElementFullscreenEnabled = true }
      if with.contains("noop") { c.userContentController.addUserScript(WKUserScript(source: "void 0;", injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
      for (i, a) in args.enumerated() where a == "--flag" && i + 1 < args.count { let kv = args[i + 1].split(separator: "="); if kv.count == 2 { print("flag \(kv[0])=\(kv[1]) applied=\(WebKitFeatureFlags.set(String(kv[0]), kv[1] == "1", for: c.preferences))") } }
      w = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800), configuration: c)
    } else {
      let factory = WebKitTabFactory(persistent: false); if args.contains("--ext") { factory.extensionHost = ExtensionHost(registry: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b-\(UUID().uuidString).json")) }
      let t = factory.makeTab(id: TabID(), url: nil, profile: ProfileID(), restoredState: nil) as! WebKitTab
      keep = (factory, t); w = t.ensureLive()
    }
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false); win.isReleasedWhenClosed = false; win.contentView = w; win.orderFrontRegardless()
    w.load(URLRequest(url: URL(string: args[2])!))
    var done = false
    for _ in 0..<80 { try? await Task.sleep(nanoseconds: 500_000_000); if (try? await w.evaluateJavaScript("location.href!=='about:blank'&&document.readyState==='complete'&&((performance.getEntriesByType('navigation')[0]||{}).loadEventEnd>0)")) as? Bool == true { done = true; break } }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let r = try? await w.evaluateJavaScript("JSON.stringify((()=>{const n=performance.getEntriesByType('navigation')[0]||{};const fcp=(performance.getEntriesByName('first-contentful-paint')[0]||{}).startTime;return {dcl:Math.round(n.domContentLoadedEventEnd),load:Math.round(n.loadEventEnd),fcp:Math.round(fcp||-1),res:performance.getEntriesByType('resource').length}})())")
    print("BENCH \(plain ? (args.contains("--legacy") ? "legacy" : "plain") : "product") done=\(done) \(r ?? "nil")"); _ = keep
    exit(0)
  }
  benchApp.run()
}

// bench-local <url> <iterations> [--plain] [--with gov,pk,pkh,fs,noop] [--no-governor] [--ext]: repeated loads in ONE process, a fresh web view each time.
if args.count >= 4, args[1] == "bench-local" {
  let benchApp = NSApplication.shared; benchApp.setActivationPolicy(.accessory)
  let plain = args.contains("--plain"), n = Int(args[3]) ?? 15
  if args.contains("--no-governor") { UserDefaults.standard.set("off", forKey: "frameGovernor") }
  Task { @MainActor in
    var makeView: () -> WKWebView
    var keep: [Any] = []
    if plain {
      let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); c.applicationNameForUserAgent = "Version/27.0.1 Safari/605.1.15"
      let with = args.firstIndex(of: "--with").map { args[$0 + 1] } ?? ""
      if with.contains("gov") { c.userContentController.addUserScript(WKUserScript(source: FrameGovernor(maxHz: 120).source, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
      if with.split(separator: ",").contains("pk") { c.userContentController.addUserScript(PasskeyBridge.script()) }
      if with.contains("pkh") { let b = PasskeyBridge(); c.userContentController.addScriptMessageHandler(b, contentWorld: .page, name: "bpasskey"); keep.append(b) }
      if with.contains("fs") { c.preferences.isElementFullscreenEnabled = true }
      if with.contains("noop") { c.userContentController.addUserScript(WKUserScript(source: "void 0;", injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
      makeView = { WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800), configuration: c) }
    } else {
      let factory = WebKitTabFactory(persistent: false); keep.append(factory)
      if args.contains("--ext") { let h = ExtensionHost(registry: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b-\(UUID().uuidString).json")); factory.extensionHost = h; keep.append(h) }
      makeView = { let t = factory.makeTab(id: TabID(), url: nil, profile: ProfileID(), restoredState: nil) as! WebKitTab; keep.append(t); return t.ensureLive() }
    }
    var dcl: [Int] = [], load: [Int] = []
    for i in 0..<(n + 3) {
      let w = makeView()
      let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false); win.isReleasedWhenClosed = false; win.contentView = w; win.orderFrontRegardless()
      w.load(URLRequest(url: URL(string: args[2])!, cachePolicy: .reloadIgnoringLocalCacheData))
      for _ in 0..<100 { try? await Task.sleep(nanoseconds: 50_000_000); if (try? await w.evaluateJavaScript("document.readyState")) as? String == "complete" { break } }
      if i >= 3, let r = try? await w.evaluateJavaScript("(()=>{const n=performance.getEntriesByType('navigation')[0];return [Math.round(n.domContentLoadedEventEnd),Math.round(n.loadEventEnd)]})()") as? [Int] { dcl.append(r[0]); load.append(r[1]) }
      win.contentView = nil; win.close()
    }
    func med(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }
    print("LOCAL \(plain ? "plain" : "product") \(args.dropFirst(4).joined(separator: " ")) n=\(dcl.count) dcl_median=\(med(dcl)) load_median=\(med(load)) p90=\(load.sorted()[Int(Double(load.count) * 0.9)])"); _ = keep
    exit(0)
  }
  benchApp.run()
}
guard args.count >= 4 else { print("usage: ExtLab <dir|file|chrome:ID|firefox:SLUG> <url> <seconds> [--eval js]"); exit(2) }
let secs = Double(args[3]) ?? 10
var evalJS: String? = nil; if let i = args.firstIndex(of: "--eval"), i + 1 < args.count { evalJS = args[i + 1] }
let app = NSApplication.shared; app.setActivationPolicy(.accessory)

@MainActor final class Env: ExtensionEnvironment {
  let win = WindowID(); let prof = ProfileID(); var tab: WebKitTab?
  func windowIDs() -> [WindowID] { [win] }
  func focusedWindow() -> WindowID? { win }
  func tabs(in window: WindowID) -> [WebKitTab] { tab.map { [$0] } ?? [] }
  func selectedTab(in window: WindowID) -> WebKitTab? { tab }
  func window(of tab: TabID) -> WindowID? { win }
  func openTab(url: URL?, active: Bool, in window: WindowID?) -> WebKitTab? { nil }
  func select(_ tab: TabID) {}
  func close(_ tab: TabID) {}
  func profile(ofWindow window: WindowID) -> ProfileID? { prof }
}

Task { @MainActor in
  do {
    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("extlab-\(UUID().uuidString)", isDirectory: true)
    var source = URL(fileURLWithPath: args[1])
    if args[1].hasPrefix("chrome:") { source = try await ExtensionStore.download(.chrome(id: String(args[1].dropFirst(7))), into: work) }
    else if args[1].hasPrefix("firefox:") { source = try await ExtensionStore.download(.firefox(slug: String(args[1].dropFirst(8))), into: work) }
    let p = try ExtensionPackage.prepare(source: source, into: work.appendingPathComponent("installed"))
    print("package: \(p.name) \(p.version) mv\(p.manifestVersion) dir=\(p.directory.path)\n  notes: \(p.notes)\n  perms: \(p.permissions)\n  hosts: \(p.hostPatterns)")
    let host = ExtensionHost(registry: work.appendingPathComponent("extensions.json")); let persist = args.contains("--persistent"); host.persistent = persist; host.allowPrivate = !persist; host.blockedSites = []
    let factory = WebKitTabFactory(persistent: persist); factory.extensionHost = host
    let env = Env(); host.environment = env
    _ = factory.configuration(for: env.prof)
    await host.install(p, permissions: p.permissions, hosts: p.hostPatterns)
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    let t = factory.makeTab(id: TabID(), url: nil, profile: env.prof, restoredState: nil) as! WebKitTab
    env.tab = t; let w = t.ensureLive()
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false); win.isReleasedWhenClosed = false; win.contentView = w; win.orderFrontRegardless()
    host.didOpen(window: env.win, profile: env.prof); host.didFocus(window: env.win, profile: env.prof); host.didOpen(t, profile: env.prof); t.isActive = true; host.didActivate(t, previous: nil, profile: env.prof)
    for l in host.status() { print("status: \(l)") }
    w.load(URLRequest(url: URL(string: args[2])!))
    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
    if let js = evalJS { let r = try? await w.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page); print("EVAL: \(r ?? "nil")") }
    for l in host.status() { print("status: \(l)") }
    print("loadErrors: \(host.loadErrors)")
  } catch { print("FAIL: \(error)") }
  exit(0)
}
app.run()
