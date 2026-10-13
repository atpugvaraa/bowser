import AppKit
import BrowserCore
import Darwin
import WebKit

/// One browser tab backed by WKWebView. The web view exists only while live: hibernate() destroys it
/// (freeing the WebContent process memory) and keeps just enough to restore (URL, history, scroll via interactionState).
/// The website data store lives in the shared configuration, so cookies/logins survive hibernation.
@MainActor
public final class WebKitTab: NSObject, WKNavigationDelegate, WKUIDelegate, EngineTab {
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
  /// Page asked for a new window/tab (window.open, target=_blank): the engine opens it as a tab. Never a raw popup window.
  public var onOpenURL: ((URL) -> Void)?
  /// A user click on a mailto:/tel:/app link: hand it to the system (only after a real click, see NavigationPolicy).
  public var onOpenExternally: ((URL) -> Void)?
  /// Camera/microphone request from a page. Default DENY; the UI shows a prompt and may remember the answer per profile.
  public var decideCapture: ((_ host: String, _ camera: Bool, _ microphone: Bool) async -> Bool)?
  public var onDownload: ((WKDownload) -> Void)?
  public var onProgress: ((Double) -> Void)?
  public private(set) var lastBlockedNavigation: String?
  public private(set) var events: [String] = []             // recent delegate events (diagnostics)
  public private(set) var lastLoadError: String?          // "domain:code" of the last failed load (for the UI and tests)
  public private(set) var canGoBack = false
  public private(set) var canGoForward = false
  public private(set) var progress: Double = 0
  public private(set) var isLoadingPage = false
  private var observers: [NSKeyValueObservation] = []
  /// A page that opened itself (window.open) asked to close itself (window.close()): the engine closes the tab.
  public var onPageRequestedClose: (() -> Void)?
  private var dialogs = DialogThrottle()
  private var dialogHost: String?                      // the throttle follows the SITE: a page reloading itself cannot reset it
  fileprivate var pendingDialogs: [UUID: () -> Void] = [:]
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
  public func load(_ u: URL) {
    let wasLive = webView != nil
    url = u; showingStoppedPage = false
    let w = ensureLive()                              // a fresh view with no saved state already starts loading `url`
    if wasLive || restoredFromState { w.load(URLRequest(url: u)) }
  }
  public func goBack() { webView?.goBack() }
  public func goForward() { webView?.goForward() }
  public func reload() { if let w = webView { if showingStoppedPage, let u = url { showingStoppedPage = false; w.load(URLRequest(url: u)) } else if w.url != nil { w.reload() } else if let u = url { w.load(URLRequest(url: u)) } } }
  public func stopLoading() { webView?.stopLoading() }
  public var currentURL: URL? { webView?.url ?? url }
  public var currentTitle: String? { (webView?.title).flatMap { $0.isEmpty ? nil : $0 } ?? (title.isEmpty ? nil : title) }
  /// Archive of the live page's interaction state (or the saved one while hibernated).
  public func captureState() -> Data? {
    if let w = webView, let st = w.interactionState { return try? NSKeyedArchiver.archivedData(withRootObject: st, requiringSecureCoding: false) }
    return savedState
  }
  public func setURL(_ u: URL) { url = u }

  /// Make the tab live (creating the web view if hibernated) and return it.
  @discardableResult public func ensureLive() -> WKWebView {
    if let w = webView { return w }
    let w = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    w.navigationDelegate = self
    w.uiDelegate = self
    w.isInspectable = true                           // Web Inspector via Safari's Develop menu (devtools requirement); local user only
    webView = w
    observe(w)
    DirtyTracker.shared.forget(w)                    // a recycled object address must not inherit another view's state
    if let s = savedState, let obj = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSData.self, NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSURL.self, NSDate.self], from: s) {
      w.interactionState = obj                       // restores history + scroll + form hints
      restoredFromState = true
      savedState = nil                               // consumed: a later nil interactionState must not resurrect this old page
    } else if let u = url { restoredFromState = false; w.load(URLRequest(url: u)) }
    if let b = stoppedForBytes {                      // the renderer was stopped for using too much memory: explain, don't re-run the page
      stoppedForBytes = nil; restoredFromState = false
      w.loadHTMLString(ErrorPage.html(url: url?.absoluteString, title: "This page was stopped", message: "It was using \(b >> 20) MB of memory, more than this browser allows for one tab, so it was stopped to keep your Mac responsive. Press Reload to load it again, or raise the limit in Settings.", code: nil), baseURL: url)      // base = the real address: the tab keeps its URL (session, archive, address bar)
      showingStoppedPage = true
    }
    return w
  }

  /// Destroy the web view, keeping restorable state. Returns false if already hibernated.
  @discardableResult public func hibernate(force: Bool = false) -> Bool {
    guard let w = webView else { return false }
    if isActive && !force { return false }
    url = w.url ?? url; title = w.title ?? title
    if let st = w.interactionState, let data = try? NSKeyedArchiver.archivedData(withRootObject: st, requiringSecureCoding: false) { savedState = data } else { savedState = nil }   // never keep a stale state over a newer url
    DirtyTracker.shared.forget(w)
    resolvePendingDialogs()                           // a sheet still open on a view we are destroying: end it, answer the page with defaults
    observers.removeAll(); w.uiDelegate = nil
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
  public var memoryBytes: UInt64? { memoryFootprint }
  public private(set) var memoryStopCount = 0
  private var stoppedForBytes: UInt64?
  private var showingStoppedPage = false
  public var hasUnsavedInput: Bool { webView.map { DirtyTracker.shared.isDirty($0) } ?? false }
  /// Memory cap exceeded: kill the renderer (state is NOT kept: a runaway page must not be resumed) and, the next time the tab is
  /// shown, display an explanation. Reload / the address bar still loads the real URL: the user stays in control.
  public func shedForMemory(bytes: UInt64) {
    guard webView != nil else { return }
    memoryStopCount += 1; stoppedForBytes = bytes
    hibernate(force: true); savedState = nil
  }

  public nonisolated static func footprint(pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return rc == 0 ? info.ri_phys_footprint : nil
  }

  // MARK: WKNavigationDelegate
  public func webView(_ w: WKWebView, didCommit n: WKNavigation!) { let h = w.url?.host; if h != dialogHost { dialogHost = h; dialogs.reset() } }
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

// MARK: observation, navigation policy, popups, downloads, capture, errors
extension WebKitTab {
  fileprivate func observe(_ w: WKWebView) {
    observers = [
      w.observe(\.title, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.title = v.title ?? ""; self?.onChange?() } },
      w.observe(\.url, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { if let u = v.url { self?.url = u }; self?.onChange?() } },
      w.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.progress = v.estimatedProgress; self?.onProgress?(v.estimatedProgress) } },
      w.observe(\.isLoading, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.isLoadingPage = v.isLoading; self?.onChange?() } },
      w.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack; self?.onChange?() } },
      w.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward; self?.onChange?() } },
    ]
    canGoBack = w.canGoBack; canGoForward = w.canGoForward
  }

  // Navigation policy: the pure rules in NavigationPolicy, enforced here.
  public func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    note("action \(action.request.url?.lastPathComponent ?? "?") download=\(action.shouldPerformDownload)")
    let click = action.navigationType == .linkActivated
    let main = action.targetFrame?.isMainFrame ?? true
    switch NavigationPolicy.decide(url: action.request.url, userInitiated: click, isMainFrame: main) {
    case .allow: decisionHandler(action.shouldPerformDownload ? .download : .allow)
    case .openExternally: if let u = action.request.url { onOpenExternally?(u) }; decisionHandler(.cancel)
    case .block(let why): lastBlockedNavigation = "\(action.request.url?.absoluteString ?? "?"): \(why)"; decisionHandler(.cancel)
    }
  }
  public func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
    note("response mime=\(response.response.mimeType ?? "?") canShow=\(response.canShowMIMEType)")
    decisionHandler(response.canShowMIMEType ? .allow : .download)
  }
  public func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { note("action->download"); onDownload?(d) }
  public func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { note("response->download"); onDownload?(d) }
  fileprivate func note(_ e: String) { events.append(e); if events.count > 40 { events.removeFirst(events.count - 40) } }

  // Load failures (including untrusted certificates): a safe built-in page, no bypass.
  public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError error: Error) { showError(w, error) }
  public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError error: Error) { showError(w, error) }
  private func showError(_ w: WKWebView, _ error: Error) {
    let e = error as NSError
    lastLoadError = "\(e.domain):\(e.code)"
    if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }          // our own cancels (policy / superseded loads)
    if e.domain == "WebKitErrorDomain" && e.code == 102 { return }                       // frame load interrupted (e.g. became a download)
    let d = ErrorPage.describe(domain: e.domain, code: e.code)
    let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? url?.absoluteString
    w.loadHTMLString(ErrorPage.html(url: failing, title: d.title, message: d.message, code: e.code), baseURL: nil)
  }

  // Popups: never a raw window. window.open / target=_blank become a tab (through the engine).
  public func webView(_ w: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let u = action.request.url, case .allow = NavigationPolicy.decide(url: u, userInitiated: action.navigationType == .linkActivated, isMainFrame: true) { onOpenURL?(u) }
    return nil
  }

  // JavaScript dialogs: sheets on the visible window only, throttled, sanitised, answered exactly once.
  // A tab that is not on screen (background / sleeping) NEVER blocks the UI: its dialog is dismissed with the default answer.
  private func host(_ f: WKFrameInfo) -> String { DialogText.sanitize(f.securityOrigin.host.isEmpty ? "This page" : f.securityOrigin.host, maxLines: 1, maxChars: 100) }
  private func canPresent(_ w: WKWebView) -> Bool { guard let win = w.window else { return false }; return win.isVisible && !dialogs.suppressed }

  /// Shows `a` as a sheet; `finish` is called EXACTLY once (user answer, or the default if the tab sleeps/closes meanwhile).
  private func presentSheet(_ a: NSAlert, in w: WKWebView, defaultAnswer: @escaping @MainActor () -> Void, answer: @escaping @MainActor (NSApplication.ModalResponse, Bool) -> Void) {
    guard let win = w.window else { defaultAnswer(); return }
    var box: NSButton?
    if dialogs.shouldOfferSuppress() { let b = NSButton(checkboxWithTitle: "Stop this page from showing more dialogs", target: nil, action: nil); a.accessoryView = b; box = b }
    dialogs.recordShown()
    let once = Once(); let token = UUID()
    pendingDialogs[token] = { [weak self, weak win] in                       // the tab is going away: end the sheet, answer with defaults
      if once.fire() { if let win, let sheet = a.window as NSWindow? { win.endSheet(sheet) }; MainActor.assumeIsolated { defaultAnswer() } }
      self?.pendingDialogs[token] = nil
    }
    a.beginSheetModal(for: win) { [weak self] r in
      MainActor.assumeIsolated {
        self?.pendingDialogs[token] = nil
        guard once.fire() else { return }
        let sup = box?.state == .on; if sup { self?.dialogs.suppress() }
        answer(r, sup)
      }
    }
  }
  fileprivate func resolvePendingDialogs() { let all = pendingDialogs.values; pendingDialogs.removeAll(); for r in all { r() } }

  public func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
    guard canPresent(w) else { completionHandler(); return }
    let a = NSAlert(); a.messageText = "\(host(f)) says"; a.informativeText = DialogText.sanitize(message); a.addButton(withTitle: "OK")
    presentSheet(a, in: w, defaultAnswer: { completionHandler() }) { _, _ in completionHandler() }
  }
  public func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
    guard canPresent(w) else { completionHandler(false); return }
    let a = NSAlert(); a.messageText = "\(host(f)) says"; a.informativeText = DialogText.sanitize(message); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    presentSheet(a, in: w, defaultAnswer: { completionHandler(false) }) { r, sup in completionHandler(r == .alertFirstButtonReturn && !sup) }
  }
  public func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
    guard canPresent(w) else { completionHandler(nil); return }
    let a = NSAlert(); a.messageText = "\(host(f)) says"; a.informativeText = DialogText.sanitize(prompt); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = DialogText.sanitize(defaultText ?? "", maxLines: 1, maxChars: 500); a.accessoryView = field
    presentSheet(a, in: w, defaultAnswer: { completionHandler(nil) }) { r, sup in completionHandler(r == .alertFirstButtonReturn && !sup ? field.stringValue : nil) }
  }
  // File inputs / uploads
  public func webView(_ w: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
    guard let win = w.window, win.isVisible else { completionHandler(nil); return }          // a background tab cannot open file dialogs
    let p = NSOpenPanel(); p.allowsMultipleSelection = parameters.allowsMultipleSelection; p.canChooseDirectories = parameters.allowsDirectories; p.canChooseFiles = true
    p.message = "\(host(f)) wants to upload files"
    let once = Once()
    p.beginSheetModal(for: win) { r in MainActor.assumeIsolated { if once.fire() { completionHandler(r == .OK ? p.urls : nil) } } }
  }
  /// window.close() from a script-opened page.
  public func webViewDidClose(_ w: WKWebView) { onPageRequestedClose?() }

  // Camera / microphone: deny unless the UI says yes.
  public func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
    guard let ask = decideCapture else { decisionHandler(.deny); return }
    let cam = type == .camera || type == .cameraAndMicrophone, mic = type == .microphone || type == .cameraAndMicrophone
    Task { @MainActor in decisionHandler(await ask(origin.host, cam, mic) ? .grant : .deny) }
  }
}

extension WebKitTab {
  /// ObjC selectors WebKit must be able to call on a WebKitTab / DownloadCoordinator. A Swift method whose name is slightly wrong
  /// compiles fine but does not satisfy the protocol, is not exposed to Objective-C, and is silently NEVER called (this happened
  /// with `didBecomeDownload` vs the real Swift name `didBecome`). Checking the real ObjC selectors at runtime catches that.
  /// Returns the selectors that are missing (must be empty).
  public static func missingDelegateMethods() -> [String] {
    let tab = ["webView:decidePolicyForNavigationAction:decisionHandler:", "webView:decidePolicyForNavigationResponse:decisionHandler:",
               "webView:navigationAction:didBecomeDownload:", "webView:navigationResponse:didBecomeDownload:",
               "webView:didFailProvisionalNavigation:withError:", "webView:didFailNavigation:withError:", "webView:didFinishNavigation:",
               "webViewWebContentProcessDidTerminate:", "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
               "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
               "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:", "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
               "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:", "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:", "webViewDidClose:", "webView:didCommitNavigation:"]
    let dl = ["download:decideDestinationUsingResponse:suggestedFilename:completionHandler:", "downloadDidFinish:", "download:didFailWithError:resumeData:"]
    return tab.filter { !WebKitTab.instancesRespond(to: Selector($0)) } + dl.filter { !DownloadCoordinator.instancesRespond(to: Selector($0)) }
  }
}
