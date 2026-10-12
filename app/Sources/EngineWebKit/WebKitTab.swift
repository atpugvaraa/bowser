import AppKit
import BrowserCore
import Darwin
import WebKit

/// One browser tab backed by WKWebView. The web view exists only while live: hibernate() destroys it
/// (freeing the WebContent process memory) and keeps just enough to restore (URL, history, scroll via interactionState).
/// The website data store lives in the shared configuration, so cookies/logins survive hibernation.
@MainActor
public final class WebKitTab: NSObject, WKNavigationDelegate, EngineTab {
  public let id: TabID
  public private(set) var url: URL?
  public private(set) var title: String = ""
  public private(set) var webView: WKWebView?
  public private(set) var hibernateCount = 0
  /// Set by the owner while this tab is selected in any window. hibernate() refuses an active tab unless forced
  /// (the user may have switched to it while a slow policy pass was running).
  public var isActive = false
  public private(set) var crashCount = 0
  public private(set) var restoredFromState = false      // last resume used saved history (false = fell back to a plain URL load)
  public private(set) var isCrashLooping = false
  private var crashTimes: [Date] = []
  /// Opaque restore state (history + scroll). Persist with Store.setTabState; pass back via `restore(state:)` after an app restart.
  public var restorableState: Data? { savedState }
  public func restore(state: Data?) { savedState = state }
  public var onChange: (() -> Void)?
  public var onCrash: (() -> Void)?
  private let configuration: WKWebViewConfiguration
  private var savedState: Data?

  /// Runs in EVERY frame (iframes included). Each frame reports its dirty state to native code, which aggregates per web view.
  /// Limitation: custom editors that never fire `input` (canvas/contenteditable shims) are not seen.
  static let dirtyScript = WKUserScript(source: """
    (function(){ if (window.__bdirtyInstalled) return; window.__bdirtyInstalled = true;
      var id = Math.random().toString(36).slice(2), dirty = false;
      function post(v){ if (v === dirty) return; dirty = v; try { window.webkit.messageHandlers.bdirty.postMessage({id: id, dirty: v}); } catch(e){} }
      addEventListener('input', function(e){ var t=e.target; if (t && (t.tagName==='INPUT'||t.tagName==='TEXTAREA'||t.tagName==='SELECT'||t.isContentEditable)) post(true); }, true);
      addEventListener('submit', function(){ post(false); }, true);
      addEventListener('pagehide', function(){ post(false); }, true); })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

  /// Counts open WebSocket / EventSource objects per frame (page-created, main-world). Workers' sockets are not visible.
  static let connScript = WKUserScript(source: """
    (function(){ if (window.__bconnInstalled) return; window.__bconnInstalled = true;
      var id = Math.random().toString(36).slice(2), open = 0;
      function report(){ try { window.webkit.messageHandlers.bconn.postMessage({id: id, n: open}); } catch(e){} }
      function wrap(name){ var Orig = window[name]; if (!Orig || typeof Proxy !== 'function') return;
        var P = new Proxy(Orig, { construct: function(target, args, newTarget){
          var s = Reflect.construct(target, args, newTarget === P ? target : newTarget); open++; report(); var done = false;
          function fin(){ if (!done) { done = true; open = Math.max(0, open - 1); report(); } }
          try { s.addEventListener('close', fin); s.addEventListener('error', function(){ if (s.readyState === 2) fin(); });
            var oc = s.close; s.close = function(){ fin(); return oc.apply(this, arguments); }; } catch(e){}
          return s; } });
        window[name] = P; }
      wrap('WebSocket'); wrap('EventSource');
      addEventListener('pagehide', function(){ open = 0; report(); }, true); })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

  /// `configuration` carries the profile's WKWebsiteDataStore; share one per profile.
  public init(id: TabID = TabID(), url: URL?, configuration: WKWebViewConfiguration) {
    self.id = id; self.url = url; self.configuration = configuration
    super.init()
    DirtyTracker.install(on: configuration)
  }

  public var isLive: Bool { webView != nil }
  @discardableResult public func ensureLiveView() -> Bool { let was = webView == nil; ensureLive(); return was }
  public func setURL(_ u: URL) { url = u }

  /// Make the tab live (creating the web view if hibernated) and return it.
  @discardableResult public func ensureLive() -> WKWebView {
    if let w = webView { return w }
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    w.navigationDelegate = self
    webView = w
    DirtyTracker.shared.forget(w)                    // a recycled object address must not inherit another view's state
    if let s = savedState, let obj = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSData.self, NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSURL.self, NSDate.self], from: s) {
      w.interactionState = obj                       // restores history + scroll + form hints
      restoredFromState = true
    } else if let u = url { restoredFromState = false; w.load(URLRequest(url: u)) }
    return w
  }

  /// Destroy the web view, keeping restorable state. Returns false if already hibernated.
  @discardableResult public func hibernate(force: Bool = false) -> Bool {
    guard let w = webView else { return false }
    if isActive && !force { return false }
    url = w.url ?? url; title = w.title ?? title
    if let st = w.interactionState, let data = try? NSKeyedArchiver.archivedData(withRootObject: st, requiringSecureCoding: false) { savedState = data } else { savedState = nil }   // never keep a stale state over a newer url
    DirtyTracker.shared.forget(w)
    w.stopLoading(); w.navigationDelegate = nil
    w.removeFromSuperview()
    webView = nil                                    // last strong ref: WebContent process can exit
    hibernateCount += 1
    return true
  }

  /// Current protection-relevant state. Never hangs: every WebKit round-trip has a timeout (a hung WebContent is exactly
  /// when we want to be able to shed a tab). Fails CLOSED on script errors (assume dirty), OPEN on a hung process.
  public func signals(timeout: TimeInterval = 1.5) async -> TabSignals {
    var s = TabSignals()
    guard let w = webView else { return s }
    s.isLoading = w.isLoading
    s.isCapturing = w.cameraCaptureState != .none || w.microphoneCaptureState != .none
    s.hasDirtyForm = DirtyTracker.shared.isDirty(w)
    s.hasLiveConnection = DirtyTracker.shared.hasConnection(w)
    let state: Int? = await roundTrip(timeout) { done in w.requestMediaPlaybackState { done($0.rawValue) } }
    if let state { s.isPlayingMedia = state == WKMediaPlaybackState.playing.rawValue } else { s.isUnresponsive = true }
    return s
  }

  /// Run a callback-style WebKit call with a timeout; resumes exactly once.
  private func roundTrip<T: Sendable>(_ timeout: TimeInterval, _ body: (@escaping @Sendable (T) -> Void) -> Void) async -> T? {
    await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
      let once = Once()
      body { v in if once.fire() { c.resume(returning: v) } }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { if once.fire() { c.resume(returning: nil) } }
    }
  }

  /// WebContent process id (private KVC, guarded). Nil if unavailable.
  public var processID: pid_t? {
    guard let w = webView, w.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return nil }
    let v = w.value(forKey: "_webProcessIdentifier") as? Int32
    return (v ?? 0) > 0 ? v : nil
  }

  /// Physical footprint of this tab's WebContent process in bytes (may be shared by several tabs).
  public var memoryFootprint: UInt64? { processID.flatMap(WebKitTab.footprint(pid:)) }

  public nonisolated static func footprint(pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return rc == 0 ? info.ri_phys_footprint : nil
  }

  // MARK: WKNavigationDelegate
  public func webView(_ w: WKWebView, didFinish n: WKNavigation!) { url = w.url ?? url; title = w.title ?? title; onChange?() }
  public func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
    crashCount += 1
    DirtyTracker.shared.forget(w)                    // the dead process's dirty frames / sockets are gone
    onCrash?()                                       // caller decides: reload (default) or show crash page
  }
  /// Default crash recovery: reload the last URL in the same web view.
  /// Gives up after 3 crashes in 60 s (a page that kills its process on load must not reload forever).
  @discardableResult public func recoverFromCrash() -> Bool {
    let now = Date(); crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
    if crashTimes.count > 3 { isCrashLooping = true; return false }
    guard let w = webView else { return false }
    if w.url != nil { w.reload() } else if let u = url { w.load(URLRequest(url: u)) }
    return true
  }
}

final class Once: @unchecked Sendable {
  private let lock = NSLock(); private var done = false
  func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Aggregates per-frame dirty reports (from the user script) into a per-web-view answer. One handler per configuration.
@MainActor
final class DirtyTracker: NSObject, WKScriptMessageHandler {
  static let shared = DirtyTracker()
  static let dirtyMaxAge: TimeInterval = 12 * 3600      // a page can lie; an unsaved-input claim protects a tab for at most 12 h
  static let maxFramesPerView = 64
  private var dirtyFrames: [ObjectIdentifier: [String: Date]] = [:]
  private var connFrames: [ObjectIdentifier: [String: Int]] = [:]
  private struct WeakUCC { weak var v: WKUserContentController? }
  private static var installed: [ObjectIdentifier: WeakUCC] = [:]
  static func install(on config: WKWebViewConfiguration) {
    let ucc = config.userContentController, key = ObjectIdentifier(ucc)
    if let w = installed[key], w.v === ucc { return }          // same live controller already set up
    installed = installed.filter { $0.value.v != nil }          // drop dead entries (address reuse can't fool us)
    installed[key] = WeakUCC(v: ucc)
    ucc.addUserScript(WebKitTab.dirtyScript)
    ucc.addUserScript(WebKitTab.connScript)
    ucc.add(WeakHandler(shared), name: "bdirty")
    ucc.add(WeakHandler(shared), name: "bconn")
  }
  func isDirty(_ w: WKWebView, now: Date = Date()) -> Bool {
    (dirtyFrames[ObjectIdentifier(w)] ?? [:]).values.contains { now.timeIntervalSince($0) < DirtyTracker.dirtyMaxAge }
  }
  func hasConnection(_ w: WKWebView) -> Bool { (connFrames[ObjectIdentifier(w)] ?? [:]).values.contains { $0 > 0 } }
  func forget(_ w: WKWebView) { dirtyFrames[ObjectIdentifier(w)] = nil; connFrames[ObjectIdentifier(w)] = nil }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let w = m.webView, let body = m.body as? [String: Any], let id = body["id"] as? String,
          id.count >= 1, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }   // hostile/oversized ids ignored
    let k = ObjectIdentifier(w)
    if m.name == "bconn" {
      guard let n = body["n"] as? Int else { return }
      if n <= 0 { connFrames[k]?[id] = nil; return }
      if connFrames[k]?[id] == nil, (connFrames[k]?.count ?? 0) >= DirtyTracker.maxFramesPerView { return }
      connFrames[k, default: [:]][id] = min(n, 1000); return
    }
    guard let d = body["dirty"] as? Bool else { return }
    if d {
      if dirtyFrames[k]?[id] == nil, (dirtyFrames[k]?.count ?? 0) >= DirtyTracker.maxFramesPerView { return }
      dirtyFrames[k, default: [:]][id] = Date()
    } else { dirtyFrames[k]?[id] = nil }
  }
}
final class WeakHandler: NSObject, WKScriptMessageHandler {
  weak var target: DirtyTracker?
  init(_ t: DirtyTracker) { target = t }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { MainActor.assumeIsolated { target?.userContentController(c, didReceive: m) } }
}
