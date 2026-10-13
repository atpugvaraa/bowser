import AppKit
import Foundation
import IOKit.ps
import WebKit

/// LTPO-style adaptive frame rate for pages. WebKit has no public or private knob to slow a running page below the display rate, so a user script
/// paces `requestAnimationFrame` itself: full rate while the user interacts (pointer, wheel, keys, touch, gamepad, fullscreen, playing media),
/// half after `settleMs` without input, a quarter after `idleMs`. The ceiling (`maxHz`) follows power: AC = display max, battery = 60, low battery/Low Power Mode = 30.
/// Skipped frames cost almost nothing (no page JS, no draw), which is where the CPU/GPU saving comes from. CSS animations and video are untouched.
public struct FrameGovernor: Equatable, Sendable {
  public var maxHz: Int
  public var settleMs = 2000
  public var idleMs = 10_000
  public var enabled = true
  public init(maxHz: Int, settleMs: Int = 2000, idleMs: Int = 10_000, enabled: Bool = true) { self.maxHz = maxHz; self.settleMs = settleMs; self.idleMs = idleMs; self.enabled = enabled }

  /// Ceiling for a power state. `displayMax` is the panel's maximumFramesPerSecond (120 on ProMotion).
  public static func ceiling(displayMax: Int, onAC: Bool, batteryPercent: Int?, lowPowerMode: Bool) -> Int {
    let d = max(displayMax, 30)
    if lowPowerMode { return min(d, 30) }
    if onAC { return d }
    return (batteryPercent ?? 100) < 30 ? min(d, 30) : min(d, 60)
  }
  /// The governor for the machine's current power state. UserDefaults `frameGovernor` = "off" disables it (pages then run at WebKit's default 60 fps).
  @MainActor public static func forCurrentPower() -> FrameGovernor {
    var onAC = true, pct: Int?
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
      onAC = (IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?) == kIOPSACPowerValue
      for ps in list { if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any], let c = d[kIOPSCurrentCapacityKey] as? Int { pct = c } }
    }
    let display = NSScreen.main?.maximumFramesPerSecond ?? 60
    var g = FrameGovernor(maxHz: ceiling(displayMax: display, onAC: onAC, batteryPercent: pct, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled))
    g.enabled = UserDefaults.standard.string(forKey: "frameGovernor") != "off"
    return g
  }
  public var config: String { "{\"maxHz\":\(maxHz),\"settleMs\":\(settleMs),\"idleMs\":\(idleMs),\"on\":\(enabled)}" }
  public var source: String { Self.script.replacingOccurrences(of: "__CONFIG__", with: config) }
  public var updateJS: String { "window.__fg&&__fg.set(\(config))" }

  // JS-BEGIN
  static let script = #"""
(function(){ if (window.__fg) return;
  var raf = window.requestAnimationFrame.bind(window);
  var C = __CONFIG__, lastInput = performance.now(), playing = new Set(), nextId = 1, queue = [], pending = false, pendingSince = 0, lastRun = 0, current = [], st = window.setTimeout.bind(window);
  function poke(){ lastInput = performance.now(); }
  function mediaPlaying(){ if (!playing.size) return false; playing.forEach(function(m){ if (!m.isConnected || m.paused || m.ended) playing.delete(m); }); return playing.size > 0; }
  function hz(){
    if (!C.on || document.fullscreenElement || mediaPlaying()) return C.maxHz;
    var e = performance.now() - lastInput;
    if (e < C.settleMs) return C.maxHz;
    return e < C.idleMs ? Math.max(Math.round(C.maxHz / 2), 24) : Math.max(Math.round(C.maxHz / 4), 20);
  }
  function tick(t){
    pending = false;
    var now = performance.now(), want = hz();
    if (want < 100 && now - lastRun < 1000 / want - 2) {                                          // not yet: sleep on a timer instead of waking at every display frame
      pending = true; pendingSince = now; var wait = 1000 / want - (now - lastRun) - 5;
      if (wait > 3) st(function(){ raf(tick); }, wait); else raf(tick);
      return;
    }
    lastRun = now;
    current = queue; queue = [];
    for (var i = 0; i < current.length; i++) { var it = current[i]; if (it.dead) continue; try { it.cb(t); } catch (e) { st(function(){ throw e; }); } }
    current = [];
    if (queue.length && !pending) { pending = true; pendingSince = performance.now(); raf(tick); }
  }
  window.requestAnimationFrame = function(cb){
    if (typeof cb !== 'function') throw new TypeError("Failed to execute 'requestAnimationFrame' on 'Window': The callback provided as parameter 1 is not a function.");
    var id = nextId++; queue.push({ id: id, cb: cb, dead: false });
    if (pending && performance.now() - pendingSince > 1000) pending = false;                      // watchdog: a page that cleared our timer cannot stall rendering forever
    if (!pending) { pending = true; pendingSince = performance.now(); raf(tick); }
    return id;
  };
  window.cancelAnimationFrame = function(id){
    for (var i = 0; i < queue.length; i++) if (queue[i].id === id) { queue[i].dead = true; queue.splice(i, 1); return; }
    for (var j = 0; j < current.length; j++) if (current[j].id === id) { current[j].dead = true; return; }     // cancelled by an earlier callback of the same frame
  };
  ['pointermove','pointerdown','pointerup','wheel','keydown','keyup','touchstart','touchmove','touchend','scroll','mousedown','click'].forEach(function(n){ window.addEventListener(n, poke, { capture: true, passive: true }); });
  function isMedia(e){ return e.target && e.target.tagName && /^(VIDEO|AUDIO)$/.test(e.target.tagName); }
  document.addEventListener('play', function(e){ if (isMedia(e)) playing.add(e.target); }, true);
  document.addEventListener('pause', function(e){ if (isMedia(e)) playing.delete(e.target); }, true);
  document.addEventListener('ended', function(e){ if (isMedia(e)) playing.delete(e.target); }, true);
  if (navigator.getGamepads) { var gg = navigator.getGamepads.bind(navigator); navigator.getGamepads = function(){ var r = gg();
    for (var i = 0; i < r.length; i++) { var p = r[i]; if (!p) continue; for (var a = 0; a < p.axes.length; a++) if (Math.abs(p.axes[a]) > 0.2) { poke(); return r; } for (var b = 0; b < p.buttons.length; b++) if (p.buttons[b].pressed) { poke(); return r; } }
    return r; }; }
  function clean(c){ return { maxHz: Math.min(Math.max(+c.maxHz || 60, 20), 240), settleMs: Math.max(+c.settleMs || 2000, 100), idleMs: Math.max(+c.idleMs || 10000, 200), on: c.on !== false }; }
  function set(c){ C = clean(c); for (var i = 0; i < window.frames.length; i++) { try { window.frames[i].postMessage({ __fg: C }, '*'); } catch (e) {} } }   // sub-frames (embedded games) follow the top frame
  window.addEventListener('message', function(e){ if (e.source && e.source === window.parent && e.source !== window && e.data && e.data.__fg) set(e.data.__fg); });
  window.__fg = { set: set, hz: hz };
})();
"""#
  // JS-END
}
