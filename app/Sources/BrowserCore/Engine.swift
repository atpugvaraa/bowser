import Foundation

/// Live signals the lifecycle policy needs (filled from the engine, no policy here).
public struct TabSignals: Sendable {
  public var isLoading = false
  public var isPlayingMedia = false      // playing (incl. muted video), not paused/suspended
  public var isCapturing = false         // camera or microphone active
  public var hasDirtyForm = false        // user typed into a field (any frame) and has not submitted
  public var hasLiveConnection = false   // open WebSocket / EventSource in any frame
  public var isUnresponsive = false      // engine did not answer in time (hung): shedding it is allowed, its state is unrecoverable anyway
  public init() {}
}

/// What the lifecycle manager needs from an engine tab. WebKitTab implements it; tests use a fake.
@MainActor
public protocol EngineTab: AnyObject {
  var id: TabID { get }
  var isLive: Bool { get }
  var isActive: Bool { get set }          // selected in a window right now; hibernate() must refuse it unless forced
  func signals(timeout: TimeInterval) async -> TabSignals
  @discardableResult func hibernate(force: Bool) -> Bool
  @discardableResult func ensureLiveView() -> Bool   // make the tab live; true if it was hibernated
  func captureState() -> Data?                       // opaque restore state (history + scroll) of the current page, live or hibernated
  var currentURL: URL? { get }
  var currentTitle: String? { get }
  var onChange: (() -> Void)? { get set }            // title/url/loading/history state changed (engine forwards to the UI and saves)
  var canGoBack: Bool { get }
  var canGoForward: Bool { get }
  var isLoadingPage: Bool { get }
  var progress: Double { get }
  func load(_ url: URL)
  func goBack()
  func goForward()
  func reload()
  func stopLoading()
  /// Physical memory of this tab's renderer in bytes, nil if unknown/hibernated (read by the fast memory watchdog).
  var memoryBytes: UInt64? { get }
  /// The tab exceeded its memory cap: destroy its renderer and show an explanation instead of re-running the page.
  func shedForMemory(bytes: UInt64)
  /// The user typed into a form and has not submitted: such a tab gets 2x the memory cap before it is stopped.
  var hasUnsavedInput: Bool { get }
}
public extension EngineTab {
  var hasUnsavedInput: Bool { false }
  var memoryBytes: UInt64? { nil }
  func shedForMemory(bytes: UInt64) {}
}
