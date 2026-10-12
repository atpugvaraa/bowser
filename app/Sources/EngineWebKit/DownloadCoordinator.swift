import BrowserCore
import Darwin
import Foundation
import WebKit

/// Safe downloads: sanitized file names, never overwrites an existing file, quarantine flag so Gatekeeper checks it,
/// and NEVER opens anything automatically.
@MainActor
public final class DownloadCoordinator: NSObject, WKDownloadDelegate {
  public struct Item: Sendable { public let id = UUID(); public var name: String; public var path: String?; public var state: State; public var received: Int64 = 0; public var expected: Int64 = 0 }
  public enum State: Sendable { case running, finished, failed(String) }
  public private(set) var items: [UUID: Item] = [:]
  public var onChange: (() -> Void)?
  private let directory: URL
  private var byDownload: [ObjectIdentifier: UUID] = [:]
  private var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]

  public init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) { self.directory = directory }

  public func adopt(_ d: WKDownload) { d.delegate = self }

  public func download(_ d: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
    let name = DownloadNames.unique(DownloadNames.sanitize(suggestedFilename)) { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent($0).path) }
    let dest = directory.appendingPathComponent(name)
    var item = Item(name: name, path: dest.path, state: .running); item.expected = response.expectedContentLength
    items[item.id] = item; byDownload[ObjectIdentifier(d)] = item.id
    observers[ObjectIdentifier(d)] = d.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] p, _ in
      MainActor.assumeIsolated { if let id = self?.byDownload[ObjectIdentifier(d)] { self?.items[id]?.received = p.completedUnitCount; self?.onChange?() } }
    }
    onChange?(); completionHandler(dest)
  }
  public func downloadDidFinish(_ d: WKDownload) {
    guard let id = byDownload[ObjectIdentifier(d)], let path = items[id]?.path else { return }
    Self.quarantine(path); items[id]?.state = .finished
    observers[ObjectIdentifier(d)] = nil; onChange?()
  }
  public func download(_ d: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    if let id = byDownload[ObjectIdentifier(d)] { items[id]?.state = .failed(error.localizedDescription) }
    observers[ObjectIdentifier(d)] = nil; onChange?()
  }
  /// Mark as downloaded from the internet so Gatekeeper/XProtect check it on first open.
  public nonisolated static func quarantine(_ path: String) {
    let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Browser;\(UUID().uuidString)"
    _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
  }
}
