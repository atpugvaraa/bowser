import AppKit

// Plain-UI browser shell over BrowserEngine. `--selftest <baseURL>` drives the UI programmatically and exits with a verdict.
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  withExtendedLifetime(delegate) { app.run() }
}
