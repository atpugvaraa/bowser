@preconcurrency import CoreBluetooth
import Foundation

/// Listens for FIDO hybrid adverts (service data UUID FFF9) and yields the 20-byte payloads. Created only when a passkey sheet opens, so the
/// Bluetooth permission prompt never appears otherwise. Never stores device names or identifiers; stops scanning when the stream ends.
public final class BLEAdvertSource: NSObject, AdvertSource, CBCentralManagerDelegate, @unchecked Sendable {
  private var central: CBCentralManager?
  private var continuation: AsyncStream<Data>.Continuation?
  private let queue = DispatchQueue(label: "ble.fido")
  public var onProblem: (@Sendable (String) -> Void)?
  private nonisolated(unsafe) static let uuid = CBUUID(string: Hybrid.serviceUUID)

  public func adverts() -> AsyncStream<Data> {
    AsyncStream { c in
      self.continuation = c
      c.onTermination = { [weak self] _ in self?.queue.async { self?.central?.stopScan(); self?.central?.delegate = nil; self?.central = nil } }
      self.queue.async { self.central = CBCentralManager(delegate: self, queue: self.queue) }
    }
  }
  public func centralManagerDidUpdateState(_ c: CBCentralManager) {
    switch c.state {
    case .poweredOn: c.scanForPeripherals(withServices: [Self.uuid], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    case .unauthorized: onProblem?("Bluetooth access is off for this app. Allow it in System Settings ▸ Privacy & Security ▸ Bluetooth."); continuation?.finish()
    case .poweredOff: onProblem?("Bluetooth is turned off. Turn it on to use your phone."); 
    case .unsupported: onProblem?("This Mac has no Bluetooth LE."); continuation?.finish()
    default: break
    }
  }
  public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
    if let svc = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], let d = svc[Self.uuid], d.count == 20 { continuation?.yield(d) }
  }
}
