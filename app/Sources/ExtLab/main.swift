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
