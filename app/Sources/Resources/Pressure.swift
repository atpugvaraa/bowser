import BrowserCore
import Darwin
import Dispatch
import Foundation

/// System memory pressure -> PressureLevel (public APIs only).
public enum SystemPressure {
  /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
  public static func map(sysctlValue v: Int32) -> PressureLevel {
    switch v { case 4...: return .critical; case 2...: return .warning; default: return .normal }
  }
  public static func map(event: DispatchSource.MemoryPressureEvent) -> PressureLevel {
    if event.contains(.critical) { return .critical }
    if event.contains(.warning) { return .warning }
    return .normal
  }
  /// Poll the kernel's current level (cheap sysctl, no allocations of note). Nil if unavailable.
  public static func current() -> PressureLevel? {
    var v: Int32 = 0; var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) == 0 else { return nil }
    return map(sysctlValue: v)
  }
}

/// Delivers pressure changes (event-driven, no polling) and remembers the level.
public final class PressureMonitor: @unchecked Sendable {
  private let source: DispatchSourceMemoryPressure
  private let lock = NSLock()
  private var _level: PressureLevel = SystemPressure.current() ?? .normal
  public var level: PressureLevel { lock.lock(); defer { lock.unlock() }; return _level }

  public init(queue: DispatchQueue = .main, onChange: @escaping @Sendable (PressureLevel) -> Void) {
    source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let l = SystemPressure.map(event: self.source.data)
      self.lock.lock(); let changed = self._level != l; self._level = l; self.lock.unlock()
      if changed { onChange(l) }
    }
    source.resume()
  }
  deinit { source.cancel() }
}

/// Per-process memory in bytes (phys_footprint), for the resource manager. Nil if the process is gone/not permitted.
public enum ProcessMemory {
  public static func footprint(pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return rc == 0 ? info.ri_phys_footprint : nil
  }
  public static var selfFootprint: UInt64 { footprint(pid: getpid()) ?? 0 }
}
