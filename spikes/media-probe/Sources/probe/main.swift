import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
let url = URL(string: CommandLine.arguments[1])!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let wv = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600))
let win = NSWindow(contentRect: wv.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = wv; win.orderFront(nil)
wv.load(URLRequest(url: url))
DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
app.run()
