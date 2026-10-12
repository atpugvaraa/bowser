import AppKit
import BrowserCore
import Darwin
import WebKit

/// Live signals the lifecycle policy needs (filled from WebKit, no policy here).
public struct TabSignals: Sendable {
  public var isLoading = false
  public var isPlayingMedia = false      // playing (incl. muted video), not paused/suspended
  public var isCapturing = false         // camera or microphone active
  public var hasDirtyForm = false        // user typed into a field (any frame) and has not submitted
  public var isUnresponsive = false      // WebContent did not answer in time (hung): shedding it is allowed, its state is unrecoverable anyway
  public init() {}
}

/// One browser tab backed by WKWebView. The web view exists only while live: hibernate() destroys it
/// (freeing the WebContent process memory) and keeps just enough to restore (URL, history, scroll via interactionState).
/// The website data store lives in the shared configuration, so cookies/logins survive hibernation.
@MainActor
public final class WebKitTab: NSObject, WKNavigationDelegate {
  public let id: TabID
  public private(set) var url: URL?
  public private(set) var title: String = ""
  public private(set) var webView: WKWebView?
  public private(set) var hibernateCount = 0
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

  /// `configuration` carries the profile's WKWebsiteDataStore; share one per profile.
  public init(id: TabID = TabID(), url: URL?, configuration: WKWebViewConfiguration) {
    self.id = id; self.url = url; self.configuration = configuration
    super.init()
    DirtyTracker.install(on: configuration)
  }

  public var isLive: Bool { webView != nil }
  public func setURL(_ u: URL) { url = u }

  /// Make the tab live (creating the web view if hibernated) and return it.
  @discardableResult public func ensureLive() -> WKWebView {
    if let w = webView { return w }
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    w.navigationDelegate = self
    webView = w
    if let s = savedState, let obj = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSData.self, NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSURL.self, NSDate.self], from: s) {
      w.interactionState = obj                       // restores history + scroll + form hints
      restoredFromState = true
    } else if let u = url { restoredFromState = false; w.load(URLRequest(url: u)) }
    return w
  }

  /// Destroy the web view, keeping restorable state. Returns false if already hibernated.
  @discardableResult public func hibernate() -> Bool {
    guard let w = webView else { return false }
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
  private var dirtyFrames: [ObjectIdentifier: Set<String>] = [:]
  private static var installed = Set<ObjectIdentifier>()
  static func install(on config: WKWebViewConfiguration) {
    let key = ObjectIdentifier(config.userContentController)
    guard installed.insert(key).inserted else { return }
    config.userContentController.addUserScript(WebKitTab.dirtyScript)
    config.userContentController.add(WeakHandler(shared), name: "bdirty")
  }
  func isDirty(_ w: WKWebView) -> Bool { !(dirtyFrames[ObjectIdentifier(w)]?.isEmpty ?? true) }
  func forget(_ w: WKWebView) { dirtyFrames[ObjectIdentifier(w)] = nil }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let w = m.webView, let body = m.body as? [String: Any], let id = body["id"] as? String, let d = body["dirty"] as? Bool else { return }
    let k = ObjectIdentifier(w)
    if d { dirtyFrames[k, default: []].insert(id) } else { dirtyFrames[k]?.remove(id) }
  }
}
final class WeakHandler: NSObject, WKScriptMessageHandler {
  weak var target: DirtyTracker?
  init(_ t: DirtyTracker) { target = t }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { MainActor.assumeIsolated { target?.userContentController(c, didReceive: m) } }
}
