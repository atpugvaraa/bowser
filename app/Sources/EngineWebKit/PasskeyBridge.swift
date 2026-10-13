import CryptoKit
import Foundation
import Hybrid
import WebKit

/// Takes over `navigator.credentials.create/get({publicKey})` and answers them through the phone (hybrid) transport.
/// The page script only forwards options; everything that matters is decided natively: the ORIGIN comes from WebKit's frame info, never from the page.
@MainActor
public final class PasskeyBridge: NSObject, WKScriptMessageHandlerWithReply {
  public typealias Performer = @MainActor (_ kind: String, _ rpId: String, _ origin: String, _ ctapRequest: Data) async throws -> Data
  public var performer: Performer?
  /// Called when a page asks to cancel (AbortSignal) so the UI can close.
  public var cancelCurrent: (@MainActor () -> Void)?
  private var busy = false
  public static let handlerName = "bpasskey"

  public static var script: WKUserScript { WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false) }

  public func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
    guard let body = m.body as? [String: Any], let op = body["op"] as? String else { replyHandler(nil, "NotAllowedError: bad request"); return }
    if op == "cancel" { cancelCurrent?(); replyHandler(nil, nil); return }
    guard op == "create" || op == "get", let opts = body["options"] as? [String: Any] else { replyHandler(nil, "NotAllowedError: bad request"); return }
    guard m.frameInfo.isMainFrame else { replyHandler(nil, "NotAllowedError: passkeys are only available to the top-level page"); return }
    let so = m.frameInfo.securityOrigin
    guard let origin = Passkey.originString(scheme: so.protocol, host: so.host, port: so.port) else { replyHandler(nil, "SecurityError: passkeys need a secure (https) page"); return }
    guard let performer else { replyHandler(nil, "NotSupportedError: passkeys are not available"); return }
    guard !busy else { replyHandler(nil, "NotAllowedError: another passkey request is in progress"); return }
    let host = so.host.lowercased()
    Task { @MainActor in
      self.busy = true; defer { self.busy = false }
      do { replyHandler(try await self.handle(op, opts, origin: origin, host: host, performer: performer), nil) }
      catch { replyHandler(nil, Self.domError(error)) }
    }
  }

  func handle(_ op: String, _ o: [String: Any], origin: String, host: String, performer: Performer) async throws -> [String: Any] {
    func str(_ k: String, _ d: [String: Any]? = nil) -> String? { (d ?? o)[k] as? String }
    guard let challenge = str("challenge").flatMap(Passkey.fromB64url), (16...1024).contains(challenge.count) else { throw Passkey.PasskeyError.invalid("challenge") }
    let create = op == "create"
    let rpDict = o["rp"] as? [String: Any]
    let rpId = ((create ? str("id", rpDict) : str("rpId")) ?? host).lowercased()
    guard Passkey.rpIdAllowed(rpId: rpId, originHost: host) else { throw Passkey.PasskeyError.notAllowed("SecurityError: this site may not use that relying-party id") }
    let uv = str("userVerification") ?? "preferred"
    func descriptors(_ k: String) -> [Passkey.Descriptor] {
      let list: [[String: Any]] = (o[k] as? [[String: Any]]) ?? []
      var out: [Passkey.Descriptor] = []
      for d in list.prefix(64) { if let s = d["id"] as? String, let data = Passkey.fromB64url(s) { out.append(Passkey.Descriptor(id: data)) } }
      return out
    }
    let cdj = Passkey.clientDataJSON(type: create ? "webauthn.create" : "webauthn.get", challenge: challenge, origin: origin)
    let hash = Data(SHA256.hash(data: cdj))
    let ctap: Data
    if create {
      guard let user = o["user"] as? [String: Any], let uid = str("id", user).flatMap(Passkey.fromB64url), (1...64).contains(uid.count) else { throw Passkey.PasskeyError.invalid("user") }
      let rawAlgs: [Any] = (o["algs"] as? [Any]) ?? []
      let allAlgs: [Int64] = rawAlgs.compactMap { ($0 as? NSNumber)?.int64Value }
      let algs: [Int64] = allAlgs.filter { $0 == -7 || $0 == -257 || $0 == -8 }
      let rpName = String((str("name", rpDict) ?? "").prefix(200))
      let userName = String((str("name", user) ?? "").prefix(200))
      let displayName = String((str("displayName", user) ?? "").prefix(200))
      let residentKey = str("residentKey") ?? "preferred"
      ctap = Passkey.makeCredentialRequest(rpId: rpId, rpName: rpName, userId: uid, userName: userName, displayName: displayName, clientDataHash: hash, algs: algs, exclude: descriptors("exclude"), residentKey: residentKey, userVerification: uv)
    } else {
      ctap = Passkey.getAssertionRequest(rpId: rpId, clientDataHash: hash, allow: descriptors("allow"), userVerification: uv)
    }
    let response = try await performer(create ? "create" : "get", rpId, origin, ctap)
    return create ? try Passkey.creationResult(ctapResponse: response, clientDataJSON: cdj) : try Passkey.assertionResult(ctapResponse: response, clientDataJSON: cdj)
  }

  static func domError(_ e: Error) -> String {
    if let p = e as? Passkey.PasskeyError { switch p { case .notAllowed(let m): return m; case .invalid(let m): return "TypeError: invalid \(m)" } }
    if let h = e as? HybridError {
      switch h {
      case .timeout: return "NotAllowedError: the request timed out"
      case .cancelled: return "AbortError: cancelled"
      case .authenticatorStatus(let s): return s == 0x2E ? "NotAllowedError: no matching passkey on that phone" : s == 0x27 ? "NotAllowedError: declined on the phone" : "NotAllowedError: the phone refused (\(s))"
      case .bluetoothUnavailable(let m): return "NotAllowedError: \(m)"
      default: return "NotAllowedError: could not reach the phone"
      }
    }
    if e is CancellationError { return "AbortError: cancelled" }
    return "NotAllowedError: \(e.localizedDescription)"
  }

  // The page-side shim. It forwards plain options and rebuilds WebAuthn objects from the reply; it is not trusted for anything.
  static let scriptSource = #"""
(function(){ if (window.__bpk || !window.isSecureContext) return; window.__bpk = true;
  var H = function(){ return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bpasskey; };
  if (!H() || !navigator.credentials) return;
  function b64u(buf){ var b = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength); var s = ''; for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
  function unb64u(s){ s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '='; var bin = atob(s), u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u.buffer; }
  function domErr(m){ var i = String(m).indexOf(': '); return i > 0 ? new DOMException(String(m).slice(i + 2), String(m).slice(0, i)) : new DOMException(String(m), 'NotAllowedError'); }
  var nativeGet = navigator.credentials.get.bind(navigator.credentials), nativeCreate = navigator.credentials.create.bind(navigator.credentials);
  var PKC = window.PublicKeyCredential || function PublicKeyCredential(){ throw new TypeError('Illegal constructor'); };
  function def(o, k, v){ Object.defineProperty(o, k, { value: v, enumerable: true, configurable: true }); }
  function protoOf(name, fallback){ var C = window[name]; return C && C.prototype ? C.prototype : fallback; }
  function build(r, create){
    var cred = Object.create(PKC.prototype), resp = Object.create(protoOf(create ? 'AuthenticatorAttestationResponse' : 'AuthenticatorAssertionResponse', Object.prototype));
    def(resp, 'clientDataJSON', unb64u(r.clientDataJSON));
    if (create) {
      def(resp, 'attestationObject', unb64u(r.attestationObject));
      resp.getTransports = function(){ return ['hybrid']; };
      resp.getAuthenticatorData = function(){ return unb64u(r.authenticatorData); };
      resp.getPublicKey = function(){ return r.publicKey ? unb64u(r.publicKey) : null; };
      resp.getPublicKeyAlgorithm = function(){ return r.publicKeyAlgorithm || -7; };
    } else {
      def(resp, 'authenticatorData', unb64u(r.authenticatorData)); def(resp, 'signature', unb64u(r.signature));
      def(resp, 'userHandle', r.userHandle ? unb64u(r.userHandle) : null);
    }
    def(cred, 'id', r.id); def(cred, 'rawId', unb64u(r.rawId)); def(cred, 'type', 'public-key'); def(cred, 'authenticatorAttachment', 'cross-platform'); def(cred, 'response', resp);
    cred.getClientExtensionResults = function(){ return create ? { credProps: { rk: true } } : {}; };
    cred.toJSON = function(){ var j = { id: r.id, rawId: r.rawId, type: 'public-key', authenticatorAttachment: 'cross-platform', clientExtensionResults: {}, response: { clientDataJSON: r.clientDataJSON } };
      if (create) { j.response.attestationObject = r.attestationObject; j.response.authenticatorData = r.authenticatorData; j.response.transports = ['hybrid']; if (r.publicKey) j.response.publicKey = r.publicKey; j.response.publicKeyAlgorithm = r.publicKeyAlgorithm || -7; }
      else { j.response.authenticatorData = r.authenticatorData; j.response.signature = r.signature; if (r.userHandle) j.response.userHandle = r.userHandle; }
      return j; };
    return cred;
  }
  function ids(list){ return (list || []).map(function(c){ return { id: b64u(c.id) }; }); }
  function run(op, options, signal){
    if (signal && signal.aborted) return Promise.reject(new DOMException('Aborted', 'AbortError'));
    var done = false;
    return new Promise(function(resolve, reject){
      if (signal) signal.addEventListener('abort', function(){ if (!done) { done = true; try { H().postMessage({ op: 'cancel' }); } catch (e) {} reject(new DOMException('Aborted', 'AbortError')); } });
      H().postMessage({ op: op, options: options }).then(function(r){ if (!done) { done = true; resolve(build(r, op === 'create')); } }, function(e){ if (!done) { done = true; reject(domErr(e && e.message ? e.message : e)); } });
    });
  }
  navigator.credentials.get = function(opts){
    if (!opts || !opts.publicKey) return nativeGet(opts);
    var o = opts.publicKey;
    if (opts.mediation === 'conditional') return new Promise(function(_, reject){ if (opts.signal) opts.signal.addEventListener('abort', function(){ reject(new DOMException('Aborted', 'AbortError')); }); });   // no autofill UI yet: stay pending like an idle conditional request
    return run('get', { challenge: b64u(o.challenge), rpId: o.rpId, userVerification: o.userVerification || 'preferred', allow: ids(o.allowCredentials) }, opts.signal);
  };
  navigator.credentials.create = function(opts){
    if (!opts || !opts.publicKey) return nativeCreate(opts);
    var o = opts.publicKey, sel = o.authenticatorSelection || {};
    return run('create', { challenge: b64u(o.challenge), rp: { id: o.rp && o.rp.id, name: o.rp && o.rp.name }, user: { id: b64u(o.user.id), name: o.user.name, displayName: o.user.displayName },
      algs: (o.pubKeyCredParams || []).map(function(p){ return p.alg; }), exclude: ids(o.excludeCredentials), residentKey: sel.residentKey || (sel.requireResidentKey ? 'required' : 'discouraged'), userVerification: sel.userVerification || 'preferred' }, opts.signal);
  };
  function setStatic(k, v){ try { Object.defineProperty(PKC, k, { value: v, configurable: true, writable: true }); } catch (e) {} }
  setStatic('isUserVerifyingPlatformAuthenticatorAvailable', function(){ return Promise.resolve(false); });
  setStatic('isConditionalMediationAvailable', function(){ return Promise.resolve(false); });
  setStatic('getClientCapabilities', function(){ return Promise.resolve({ hybridTransport: true, passkeyPlatformAuthenticator: false, userVerifyingPlatformAuthenticator: false, conditionalGet: false }); });
  if (!window.PublicKeyCredential) { try { Object.defineProperty(window, 'PublicKeyCredential', { value: PKC, configurable: true, writable: true }); } catch (e) {} }
})();
"""#
}
