import Foundation
import WebKit

public enum ContentBlockerError: Error { case invalidRules(String), compileFailed(String) }

/// Native content blocking through WebKit's rule-list engine (the same one Safari content blockers use): no extension runtime,
/// no JavaScript in the page, compiled once and applied before requests leave the process.
/// Rule format: Safari content-blocker JSON (https://developer.apple.com/documentation/safariservices/creating-a-content-blocker).
@MainActor
public final class ContentBlocker {
  private let store: WKContentRuleListStore
  public init(storeURL: URL) throws {
    guard let s = WKContentRuleListStore(url: storeURL) else { throw ContentBlockerError.compileFailed("cannot open rule store at \(storeURL.path)") }
    store = s
  }

  /// Build the final rule JSON: blocking rules first, then per-site exceptions (ignore-previous-rules for pages on `allowlist`).
  /// Order matters: exceptions must come AFTER the rules they cancel.
  public static func merge(blockRules: String, allowlistDomains: [String]) throws -> String {
    guard let data = blockRules.data(using: .utf8), var rules = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw ContentBlockerError.invalidRules("block rules must be a JSON array of rule objects")
    }
    let clean = allowlistDomains.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }   // no wildcards injected via user input
      .map { "*" + $0 }                                                                                                      // WebKit: "*example.com" matches the domain and subdomains
    if !clean.isEmpty {
      rules.append(["trigger": ["url-filter": ".*", "if-domain": clean], "action": ["type": "ignore-previous-rules"]])
    }
    let out = try JSONSerialization.data(withJSONObject: rules, options: [])
    return String(decoding: out, as: UTF8.self)
  }

  /// Compile (cached by identifier + content) WITHOUT installing: lets the app prepare lists before any page exists.
  public func compile(id: String, blockRules: String, allowlistDomains: [String] = []) async throws -> WKContentRuleList {
    let json = try Self.merge(blockRules: blockRules, allowlistDomains: allowlistDomains)
    let ident = "\(id)-\(Self.fingerprint(json))"
    if let existing = try? await store.contentRuleList(forIdentifier: ident) { return existing }
    do { guard let l = try await store.compileContentRuleList(forIdentifier: ident, encodedContentRuleList: json) else { throw ContentBlockerError.compileFailed("nil list") }; return l }
    catch { throw ContentBlockerError.compileFailed("\(error)") }
  }

  /// Compile (cached by identifier + content) and install on a configuration. Replaces a previous list with the same id.
  @discardableResult public func install(id: String, blockRules: String, allowlistDomains: [String] = [], on config: WKWebViewConfiguration) async throws -> Int {
    let json = try Self.merge(blockRules: blockRules, allowlistDomains: allowlistDomains)
    let count = ((try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])?.count) ?? 0
    // distinct identifier per content so a changed list is recompiled, an unchanged one is reused from the store
    let ident = "\(id)-\(Self.fingerprint(json))"
    let list: WKContentRuleList
    if let existing = try? await store.contentRuleList(forIdentifier: ident) { list = existing }
    else {
      do { guard let l = try await store.compileContentRuleList(forIdentifier: ident, encodedContentRuleList: json) else { throw ContentBlockerError.compileFailed("nil list") }; list = l }
      catch { throw ContentBlockerError.compileFailed("\(error)") }
    }
    if let old = installed[ObjectIdentifier(config.userContentController)]?[id] { config.userContentController.remove(old) }
    config.userContentController.add(list)
    installed[ObjectIdentifier(config.userContentController), default: [:]][id] = list
    return count
  }

  public func remove(id: String, from config: WKWebViewConfiguration) {
    if let old = installed[ObjectIdentifier(config.userContentController)]?[id] { config.userContentController.remove(old); installed[ObjectIdentifier(config.userContentController)]?[id] = nil }
  }

  private var installed: [ObjectIdentifier: [String: WKContentRuleList]] = [:]
  static func fingerprint(_ s: String) -> String { var h: UInt64 = 1469598103934665603; for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }; return String(h, radix: 16) }
}
