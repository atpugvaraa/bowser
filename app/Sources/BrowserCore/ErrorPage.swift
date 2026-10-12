import Foundation

/// Safe built-in error page (no scripts, everything escaped). Shown for failed loads, including untrusted certificates:
/// there is deliberately NO "proceed anyway" button in v1 (TLS errors are never silently bypassed).
public enum ErrorPage {
  public static func escape(_ s: String) -> String {
    var o = ""; o.reserveCapacity(s.count)
    for c in s.prefix(2000) {
      switch c { case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; case "\"": o += "&quot;"; case "'": o += "&#39;"; default: o.append(c) }
    }
    return o
  }
  public static func html(url: String?, title: String, message: String, code: Int?) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <title>\(escape(title))</title>
    <style>body{font:16px -apple-system,system-ui,sans-serif;margin:12vh auto;max-width:34em;padding:0 1.2em;color:#222}
    @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee}} h1{font-size:1.4em}code{word-break:break-all;opacity:.75}</style></head>
    <body><h1>\(escape(title))</h1><p>\(escape(message))</p>\(url.map { "<p><code>\(escape($0))</code></p>" } ?? "")\(code.map { "<p><small>Error \($0)</small></p>" } ?? "")</body></html>
    """
  }
  /// Map common URL-loading errors to a human message. `isCertificate` errors get the no-bypass wording.
  public static func describe(domain: String, code: Int) -> (title: String, message: String, isCertificate: Bool) {
    if domain == NSURLErrorDomain {
      switch code {
      case NSURLErrorNotConnectedToInternet: return ("You're offline", "This Mac isn't connected to the internet.", false)
      case NSURLErrorTimedOut: return ("The page took too long", "The server didn't answer in time.", false)
      case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return ("Can't find the server", "Check the address for typing mistakes.", false)
      case NSURLErrorCannotConnectToHost: return ("Can't connect to the server", "The server refused or didn't answer.", false)
      case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorSecureConnectionFailed:
        return ("This connection isn't private", "The site's security certificate can't be trusted, so the page was not loaded. Someone on this network may be trying to intercept your traffic. There is no way to continue from this page.", true)
      case NSURLErrorCancelled: return ("Cancelled", "The load was cancelled.", false)
      default: break
      }
    }
    return ("Can't open this page", "Something went wrong while loading it.", false)
  }
}
