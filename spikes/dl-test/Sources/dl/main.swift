import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
let url = URL(string: CommandLine.arguments[1])!
let mode = CommandLine.arguments.dropFirst(2).first ?? "response"      // response | action-attr
final class D: NSObject, WKNavigationDelegate, WKDownloadDelegate {
  func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
    print("response canShow=\(r.canShowMIMEType) mime=\(r.response.mimeType ?? "?")"); decisionHandler(r.canShowMIMEType ? .allow : .download) }
  func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecomeDownload d: WKDownload) { print("BECAME DOWNLOAD (response)"); d.delegate = self }
  func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecomeDownload d: WKDownload) { print("BECAME DOWNLOAD (action)"); d.delegate = self }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { print("didFail", (e as NSError).domain, (e as NSError).code) }
  func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { print("didFailProvisional", (e as NSError).domain, (e as NSError).code) }
  func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
    print("decideDestination", suggestedFilename); completionHandler(FileManager.default.temporaryDirectory.appendingPathComponent("dl-spike-\(UUID().uuidString).bin")) }
  func downloadDidFinish(_ d: WKDownload) { print("FINISHED"); exit(0) }
  func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) { print("download failed", e); exit(1) }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let d = D()
let w = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 200)); w.navigationDelegate = d
let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil)
w.load(URLRequest(url: url))
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("TIMEOUT"); exit(2) }
app.run()
