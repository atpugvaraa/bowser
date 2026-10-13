import CryptoKit
import Foundation

public protocol HybridTunnel: AnyObject, Sendable {
  func send(_ d: Data) async throws
  func receive() async throws -> Data
  func close()
}
/// Source of BLE service-data payloads (service UUID FFF9). The stream ends / is cancelled to stop scanning.
public protocol AdvertSource: Sendable { func adverts() -> AsyncStream<Data> }

public enum HybridError: Error, Equatable {
  case timeout, cancelled, unsupportedTunnelDomain(Int), tunnel(String), handshake(String), badMessage(String), authenticatorStatus(UInt8), bluetoothUnavailable(String)
}

/// The browser (client platform) side of a QR-initiated hybrid transaction.
public final class HybridClient: @unchecked Sendable {
  let scanner: AdvertSource
  let connect: @Sendable (URL) async throws -> HybridTunnel
  let timeout: TimeInterval
  public init(scanner: AdvertSource, timeout: TimeInterval = 120, connect: @escaping @Sendable (URL) async throws -> HybridTunnel) { self.scanner = scanner; self.timeout = timeout; self.connect = connect }

  /// Shows `qr` via `onQR`, waits for the phone, performs the CTAP command `ctapRequest` (command byte + CBOR) and returns the raw CTAP response (status byte + CBOR).
  public func run(flow: String, ctapRequest: Data, onQR: @escaping @Sendable (String) -> Void, onStatus: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await self.transaction(flow: flow, ctapRequest: ctapRequest, onQR: onQR, onStatus: onStatus) }
      group.addTask { try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000)); throw HybridError.timeout }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw HybridError.cancelled }
      return first
    }
  }

  func transaction(flow: String, ctapRequest: Data, onQR: @Sendable (String) -> Void, onStatus: @Sendable (String) -> Void) async throws -> Data {
    let qr = Hybrid.QR(flow: flow)
    let eidKey = Hybrid.derive(qr.secret, .eidKey, count: 64), tunnelID = Hybrid.derive(qr.secret, .tunnelID, count: 16)
    onQR(qr.url); onStatus("Scan the code with your iPhone camera")
    var advert: Hybrid.Advert?
    for await svc in scanner.adverts() { if let a = Hybrid.decryptAdvert(svc, eidKey: eidKey) { advert = a; break }; try Task.checkCancellation() }
    guard let advert else { throw Task.isCancelled ? HybridError.cancelled : HybridError.bluetoothUnavailable("no advertisement received") }
    guard let domain = Hybrid.tunnelDomain(advert.tunnelDomainID), let url = Hybrid.tunnelURL(domain: domain, routingID: advert.routingID, tunnelID: tunnelID) else { throw HybridError.unsupportedTunnelDomain(advert.tunnelDomainID) }
    onStatus("Phone found. Connecting…")
    let tunnel: HybridTunnel; do { tunnel = try await connect(url) } catch { throw HybridError.tunnel("\(error)") }
    return try await withTaskCancellationHandler {
      defer { tunnel.close() }
      let psk = Hybrid.derive(qr.secret, .psk, salt: advert.plaintext, count: 32)
      let hs = Noise.Initiator(staticKey: qr.identity, psk: psk)
      try await tunnel.send(try hs.firstMessage())
      let keys: Noise.Keys; do { keys = try hs.finish(response: try await tunnel.receive()) } catch let e as HybridError { throw e } catch { throw HybridError.handshake("\(error)") }
      let cipher = Noise.Cipher(keys)
      onStatus("Approve on your iPhone")
      let hello = try cipher.open(try await tunnel.receive())                   // post-handshake message: CBOR {1: getInfo, 3: features}
      guard (try? CBOR.decode(hello)) != nil else { throw HybridError.badMessage("post-handshake message") }
      try await tunnel.send(try cipher.seal(Data([1]) + ctapRequest))
      while true {
        let m = try cipher.open(try await tunnel.receive())
        guard let type = m.first else { throw HybridError.badMessage("empty message") }
        if type == 2 { continue }                                                 // linking update: not used
        guard type == 1 else { throw HybridError.badMessage("unexpected message type \(type)") }
        let response = m.dropFirst()
        if let shutdown = try? cipher.seal(Data([0])) { try? await tunnel.send(shutdown) }
        guard let status = response.first else { throw HybridError.badMessage("empty CTAP response") }
        guard status == 0 else { throw HybridError.authenticatorStatus(status) }
        return Data(response)
      }
    } onCancel: { tunnel.close() }
  }
}

/// wss tunnel over URLSession (subprotocol fido.cable, redirects followed).
public final class WebSocketTunnel: NSObject, HybridTunnel, @unchecked Sendable {
  let task: URLSessionWebSocketTask; let session: URLSession
  public static func connect(_ url: URL) async throws -> HybridTunnel {
    guard url.scheme == "wss" || (url.scheme == "ws" && (url.host == "127.0.0.1" || url.host == "localhost")) else { throw HybridError.tunnel("insecure tunnel URL") }
    let cfg = URLSessionConfiguration.ephemeral; cfg.httpCookieStorage = nil; cfg.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: cfg)
    let task = session.webSocketTask(with: url, protocols: ["fido.cable"]); task.maximumMessageSize = 1 << 20
    task.resume()
    return WebSocketTunnel(task: task, session: session)
  }
  init(task: URLSessionWebSocketTask, session: URLSession) { self.task = task; self.session = session }
  public func send(_ d: Data) async throws { try await task.send(.data(d)) }
  public func receive() async throws -> Data {
    switch try await task.receive() { case .data(let d): return d; case .string(let s): return Data(s.utf8); @unknown default: throw HybridError.badMessage("websocket frame") }
  }
  public func close() { task.cancel(with: .normalClosure, reason: nil); session.finishTasksAndInvalidate() }
}
