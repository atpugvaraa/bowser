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
}
