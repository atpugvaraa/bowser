import Foundation

public struct TabID: Hashable, Sendable, Codable { public let raw: UUID; public init(_ raw: UUID = UUID()) { self.raw = raw } }

public enum PressureLevel: Int, Sendable, Comparable {
  case normal = 0, warning, critical
  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum TabLiveness: Sendable { case live, hibernated }

/// Everything the lifecycle policy may know about a tab. No WebKit types: the engine fills this in.
public struct TabInfo: Sendable {
  public var id: TabID
  public var host: String?
  public var lastActive: Date
  public var liveness: TabLiveness = .live
  public var isActive = false          // currently visible/selected
  public var isPinned = false
  public var isAudible = false
  public var isPlayingMedia = false    // incl. muted video, fullscreen video
  public var isPictureInPicture = false
  public var isCapturing = false       // camera / microphone / screen capture
  public var isInCall = false          // WebRTC call / live connection
  public var isDevToolsOpen = false    // inspector attached: the user is debugging this page
  public var lastAudible: Date?        // when audio last stopped (grace period so a paused podcast/video isn't dropped at once)
  public var isDownloading = false
  public var hasUnsavedForm = false
  public var hasInflightUpload = false
  public var isLoading = false
  public var userProtected = false     // per-site / per-tab user rule
  public init(id: TabID = TabID(), host: String? = nil, lastActive: Date) { self.id = id; self.host = host; self.lastActive = lastActive }
}
