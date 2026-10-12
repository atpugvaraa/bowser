import Foundation

/// A page can spam alert()/confirm()/prompt() to lock the UI. After 3 dialogs within 10 seconds the user is offered
/// "stop this page from showing more dialogs"; once chosen, further dialogs are answered with their defaults without UI.
public struct DialogThrottle: Sendable {
  public static let window: TimeInterval = 10, freeDialogs = 3
  private var shown: [Date] = []
  public private(set) var suppressed = false
  public init() {}
  /// True if the next dialog should come with the "stop showing dialogs" option.
  public func shouldOfferSuppress(now: Date = Date()) -> Bool { shown.filter { now.timeIntervalSince($0) < Self.window }.count >= Self.freeDialogs }
  public mutating func recordShown(now: Date = Date()) { shown = shown.filter { now.timeIntervalSince($0) < Self.window } + [now] }
  public mutating func suppress() { suppressed = true }
  /// New page load: the page gets a clean slate.
  public mutating func reset() { shown = []; suppressed = false }
}
