import BrowserCore
import Foundation
import Lifecycle
import Persistence

/// Persistence of the user's hibernation settings and the learned usage habits (stored as opaque settings blobs in the session DB).
/// Reading never throws: anything missing/damaged falls back to defaults, and values are always passed through `validated()`.
@MainActor
public enum EngineSettings {
  static let policyKey = "policy.v1", usageKey = "usage.v1"

  public static func loadPolicy(from session: SessionManager) -> PolicyConfig {
    guard let data = (try? session.store.setting(policyKey)) ?? nil, !data.isEmpty,
          let cfg = try? JSONDecoder().decode(PolicyConfig.self, from: data) else { return PolicyConfig.relaxed }
    return cfg.validated()
  }
  public static func savePolicy(_ cfg: PolicyConfig, to session: SessionManager) throws {
    try session.store.setSetting(policyKey, try JSONEncoder().encode(cfg.validated()))
  }
  public static func loadUsage(from session: SessionManager) -> UsageModel {
    guard let data = (try? session.store.setting(usageKey)) ?? nil, !data.isEmpty,
          let u = try? JSONDecoder().decode(UsageModel.self, from: data) else { return UsageModel() }
    return u
  }
  public static func saveUsage(_ u: UsageModel, to session: SessionManager) throws {
    try session.store.setSetting(usageKey, try JSONEncoder().encode(u))
  }
}
