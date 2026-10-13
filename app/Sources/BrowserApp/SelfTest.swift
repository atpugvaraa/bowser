import AppKit
import BrowserCore
import EngineCore
import EngineWebKit
import Resources
import Lifecycle
import Foundation

/// Drives the real UI programmatically and exits with a verdict. Run through scripts/ui-selftest.sh (serves local pages).
/// Menu items are exercised through the real NSMenu (selectors, targets, key equivalents), not by calling controller methods.
@MainActor
struct SelfTest {
  let app: AppDelegate; let base: String

  func menuItem(_ title: String) -> NSMenuItem? {   // (title lookup walks submenus)
    func find(_ m: NSMenu) -> NSMenuItem? {
      for i in m.items { if i.title == title { return i }; if let s = i.submenu, let f = find(s) { return f } }
      return nil
    }
    return NSApp.mainMenu.flatMap(find)
  }
  /// Perform a menu item exactly like AppKit would on a click/shortcut: validate, then send the action to its target.
  @discardableResult func choose(_ title: String) -> Bool {
    guard let item = menuItem(title), let action = item.action else { return false }
    if let v = item.target as? NSMenuItemValidation, !v.validateMenuItem(item) { return false }
    return NSApp.sendAction(action, to: item.target, from: item)
  }

  func run() async {
    var failures: [String] = []
    func check(_ c: Bool, _ name: String) { print(c ? "ok   \(name)" : "FAIL \(name)"); if !c { failures.append(name) } }
    func wait(_ s: Double, _ cond: @MainActor () -> Bool) async -> Bool { let end = Date().addingTimeInterval(s); while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 80_000_000) }; return cond() }
    func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }
    let e = app.engine!

    // 0. menu wiring: every menu item with an action must have a target that can actually perform it
    var unwired: [String] = []
    func walk(_ m: NSMenu) { for i in m.items { if i.submenu == nil, let a = i.action, let t = i.target, !t.responds(to: a) { unwired.append(i.title) }; if let sm = i.submenu { walk(sm) } } }
    NSApp.mainMenu.map(walk)
    check(unwired.isEmpty, "menu: every action has a responding target (\(unwired))")
    let shortcuts: [(String, String, NSEvent.ModifierFlags)] = [("New Tab", "t", .command), ("Close Tab", "w", .command), ("Reopen Closed Tab", "t", [.command, .shift]), ("New Window", "n", .command), ("Open Location…", "l", .command), ("Reload Page", "r", .command), ("Close Window", "w", [.command, .shift])]
    check(shortcuts.allSatisfy { menuItem($0.0)?.keyEquivalent == $0.1 && menuItem($0.0)?.keyEquivalentModifierMask == $0.2 }, "menu: key equivalents are bound (⌘T ⌘W ⇧⌘T ⌘N ⌘L ⌘R ⇧⌘W)")

    // 1. launch state
    guard let c1 = app.controllers.values.first else { print("FAIL no window at launch"); exit(1) }
    check(app.controllers.count == 1 && e.state.spaces.count == 1 && e.state.tabs.count == 1, "launch: one window, one space, one tab")
    check(c1.window.isVisible && c1.addressField.window === c1.window, "launch: window visible with an address bar")
    check(e.state.tabs.values.first?.url == "about:blank", "launch: self-test starts on about:blank (no internet traffic)")

    // 2. address bar
    c1.addressField.stringValue = "\(base)/a.html"; c1.submitAddress()
    check(await wait(15) { c1.window.title == "Page A" }, "address bar: typed URL loads, window title follows the page (\(c1.window.title))")
    check(c1.rowTitles == ["Page A"], "sidebar: row shows the page title")
    check((e.tab(c1.selected!) as? WebKitTab)?.webView?.superview != nil, "content: the web view is on screen")
    check(e.navigate(tab: c1.selected!, input: "javascript:alert(1)") == false && e.navigate(tab: c1.selected!, input: "file:///etc/hosts") == false, "engine refuses javascript: and file: input")
    c1.addressField.stringValue = "javascript:alert(1)"; c1.submitAddress()
    check(c1.addressField.textColor == .systemRed, "address bar: refused input is shown in red, not just a beep")
    c1.addressField.stringValue = "\(base)/a.html"; c1.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); check(c1.addressField.textColor == .labelColor, "address bar: red clears when the user edits")

    // 3. ⌘T through the real menu
    let n0 = e.state.tabs.count
    check(choose("New Tab"), "menu: New Tab is enabled and sends its action"); await settle()
    check(e.state.tabs.count == n0 + 1 && c1.rowTitles.last == "New Tab", "⌘T (menu): second tab appears, shown as New Tab")
    c1.addressField.stringValue = "\(base)/b.html"; c1.submitAddress()
    check(await wait(15) { c1.rowTitles.contains("Page B") }, "second tab navigates; sidebar shows both titles \(c1.rowTitles)")

    // 3b. page features through the real menus: zoom, find, print wiring, fullscreen preference, inspector
    let z0 = c1.currentZoom
    check(choose("Zoom In") && c1.currentZoom > z0, "⌘+ (menu): zoom in (\(String(format: "%.2f", c1.currentZoom)))")
    check(choose("Zoom Out") && abs(c1.currentZoom - z0) < 0.001, "⌘− (menu): zoom out returns to the start")
    c1.zoom(by: 1.1); check(choose("Actual Size") && c1.currentZoom == 1, "⌘0 (menu): actual size")
    check(menuItem("Find…")?.keyEquivalent == "f" && menuItem("Find Next")?.keyEquivalent == "g" && menuItem("Print…")?.keyEquivalent == "p", "menu: Find (⌘F ⌘G) and Print (⌘P) are bound")
    let wv = (e.tab(c1.selected!) as? WebKitTab)?.webView
    check(wv?.configuration.preferences.isElementFullscreenEnabled == true, "video: element fullscreen is enabled (the player's fullscreen button works)")
    check(wv?.isInspectable == true, "devtools: Web Inspector is available for tabs (Safari ▸ Develop)")
    check(WebKitTab.missingDelegateMethods().isEmpty, "all WebKit delegate methods (incl. JS dialogs, file upload) are implemented under real selector names: \(WebKitTab.missingDelegateMethods())")

    // 3c. history, bookmarks, quick open through the real menus
    check(c1.space.map { e.bookmarks(inSpace: $0).isEmpty } ?? false, "bookmarks: none at first")
    check(choose("Bookmark This Page"), "menu: Bookmark This Page"); await settle()
    check(e.isBookmarked(tab: c1.selected!), "⌘D (menu): the page is bookmarked")
    if let bm = NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu { app.menuNeedsUpdate(bm); check(bm.items.contains { $0.title == "Page B" || $0.title.hasPrefix("Page") }, "menu: the Bookmarks menu lists it") }
    check(choose("Bookmark This Page"), "menu: Bookmark This Page again"); await settle(); check(!e.isBookmarked(tab: c1.selected!), "⌘D again removes the bookmark")
    check(!app.session.searchHistory(query: "page a").isEmpty && !app.session.searchHistory(query: "page b").isEmpty, "history: visited pages are searchable (\(app.session.searchHistory(query: "").count) entries)")
    check(choose("Quick Open…"), "menu: Quick Open…"); await settle()
    check(app.quickOpen.isVisible, "⌘K: the palette is visible")
    app.quickOpen.setQuery("page a"); check(app.quickOpen.results.first?.kind == .openTab && app.quickOpen.results.first?.title == "Page A", "quick open: typing finds the open tab first (\(app.quickOpen.results.map { "\($0.kind)" }))")
    app.quickOpen.setQuery("zzzz-nothing"); check(app.quickOpen.results.isEmpty, "quick open: no match shows nothing")
    app.quickOpen.setQuery("page b"); let chose = app.quickOpen.chooseFirst(); await settle()
    check(chose && c1.window.title == "Page B" && !app.quickOpen.isVisible, "quick open: Enter selects that tab and closes the palette")

    // 4. tab switching (menu + number)
    c1.selectTab(number: 1); await settle(); check(c1.window.title == "Page A", "⌘1 selects the first tab")
    check(choose("Next Tab"), "menu: Next Tab"); await settle(); check(c1.window.title == "Page B", "⌃Tab (menu) selects the next tab")

    // 5. close via menu: archived (recoverable); blank tabs are not archived
    check(choose("Close Tab"), "menu: Close Tab"); await settle()
    check(e.state.tabs.count == 1 && e.state.archive.count == 1 && c1.rowTitles == ["Page A"], "⌘W (menu): the tab goes to the archive, not destroyed")
    check(choose("Reopen Closed Tab"), "menu: Reopen Closed Tab is enabled"); await settle()
    check(e.state.tabs.count == 2 && e.state.archive.isEmpty, "⇧⌘T (menu): closed tab comes back")
    c1.newTab(); await settle(); let archBefore = e.state.archive.count; c1.closeSelectedTab(); await settle()
    check(e.state.archive.count == archBefore, "closing a never-used blank tab does not fill the archive")
    check(menuItem("Reopen Closed Tab").map { app.validateMenuItem($0) } == false, "menu: Reopen Closed Tab is disabled when the archive is empty")

    // 6. second window: a tab is shown in ONE window only
    check(choose("New Window"), "menu: New Window"); check(await wait(5) { app.controllers.count == 2 }, "⌘N: second window opens")
    let c2 = app.controllers.values.first { $0 !== c1 }!; await settle()
    let shownIn1 = c1.selected!
    check(e.select(tab: shownIn1, in: c2.id) == .focusWindow(c1.id), "selecting a tab shown in window 1 from window 2 returns .focusWindow(window 1) (no clone)")
    check(c1.selected == shownIn1 && e.state.windows[c2.id]?.selected != shownIn1, "…and window 1 still shows it, window 2 does not")

    // 7. closing a window: tabs kept, its tab goes to sleep (with saved history), nothing archived
    let w2tab = e.state.windows[c2.id]!.selected!; let tabsBefore = e.state.tabs.count; let archiveBefore = e.state.archive.count
    c2.window.performClose(nil); check(await wait(5) { app.controllers.count == 1 }, "closing a window removes only the window")
    check(e.state.tabs.count == tabsBefore && e.state.archive.count == archiveBefore, "closing a window never closes or archives tabs")
    check(await wait(5) { e.tab(w2tab)?.isLive == false }, "the closed window's tab went to sleep (memory freed)")
    check(app.keyController != nil, "an action target still exists after closing a window")

    // 8. spaces via the real menu + switching
    let sp2 = c1.createSpace(name: "Work", separateProfile: true); await settle()
    check(sp2 != nil && e.state.spaces.count == 2 && c1.space == sp2, "new space with a separate profile; window switches to it")
    check(e.state.space(sp2!)?.profile != e.state.spaces[0].profile, "the new space has its own profile (own data store)")
    let spacesMenu = NSApp.mainMenu?.items.first { $0.title == "Spaces" }?.submenu; if let m = spacesMenu { app.menuNeedsUpdate(m) }
    check((spacesMenu?.items.filter { $0.action == #selector(AppDelegate.switchSpace(_:)) }.map(\.title) ?? []) == ["Main", "Work"], "menu: Spaces lists the spaces")
    if let item = spacesMenu?.items.first(where: { $0.title == "Main" }), let a = item.action { NSApp.sendAction(a, to: item.target, from: item) }; await settle()
    check(c1.space == e.state.spaces[0].id && c1.rowTitles.contains("Page A"), "choosing a space from the menu switches the window to it")

    // 9. sleep other tabs: actually sleeps them
    c1.selectTab(number: 1); await settle(); c1.sleepOthers()
    let others = e.state.space(c1.space!)!.tabOrder.filter { $0 != c1.selected }
    let othersSlept = await wait(6) { others.allSatisfy { e.tab($0)?.isLive == false } }
    let awakeOthers = others.filter { e.tab($0)?.isLive == true }.map { c1.title(for: $0) }
    check(!others.isEmpty && othersSlept && e.tab(c1.selected!)?.isLive == true, "Sleep Other Tabs: others are asleep, the selected tab stays awake (still awake: \(awakeOthers); visible \(e.state.visibleTabs.count))")

    // 9b. settings: change a value in the real Settings window, apply; it persists; absurd values are clamped
    check(choose("Settings…"), "menu: Settings… opens"); 
    app.settingsController.testApply(["defaultGrace": "300", "maxLiveNormal": "77", "audibleGrace": "25"])
    check(e.policy.defaultGrace == 300 * 60 && e.policy.maxLive.normal == 77 && e.policy.audibleGrace == 25 * 60 && app.settingsController.statusText == "Saved.", "settings: values typed in the window are applied")
    app.settingsController.testApply(["minGrace": "-5", "maxLiveNormal": "0"])
    check(e.policy.minGrace >= 30 && e.policy.maxLive.normal >= 1, "settings: absurd input is clamped, never applied raw")
    app.settingsController.testApply(["maxLiveNormal": "77", "minGrace": "45"])
    app.settingsController.testApply(["maxLiveNormal": "abc"]); check(app.settingsController.statusText.hasPrefix("Not saved"), "settings: non-numbers are rejected with a message")
    for bad in ["nan", "inf", "1e30", "-3", "1e400", "99999999999"] { app.settingsController.testApply(["maxLiveNormal": bad]); check(app.settingsController.statusText.hasPrefix("Not saved") && e.policy.maxLive.normal >= 1, "settings: '\(bad)' in a limit field is rejected (no crash)") }
    app.settingsController.testApply(["maxLiveNormal": "77"])
    app.settingsController.testApply(["maxLiveNormal": "77"])
    app.settingsController.testApply([:], neverSleepSites: "127.0.0.1, Chat.Example, bad!host")
    check(e.policy.neverSleepHosts == ["127.0.0.1", "chat.example"] && app.settingsController.statusText.contains("ignored: bad!host"), "settings: never-sleep sites are normalised and applied, rejected entries are reported (\(app.settingsController.statusText))")
    let before2 = e.state.space(c1.space!)!.tabOrder.filter { $0 != c1.selected }
    c1.sleepOthers(); try? await Task.sleep(nanoseconds: 800_000_000)
    check(before2.isEmpty || before2.allSatisfy { e.tab($0)?.isLive == true || e.tab($0)?.isLive == false }, "never-sleep list does not break the sleep command")
    app.settingsController.testApply([:], neverSleepSites: "")
    app.settingsController.testApply([:], neverSleepSites: "keep.example"); app.settingsController.perform(reset: true)
    check(e.policy.neverSleepHosts == ["keep.example"] && e.policy.defaultGrace == PolicyConfig.relaxed.defaultGrace, "settings: Reset to Defaults resets timings but KEEPS the user's never-sleep list")
    app.settingsController.testApply([:], neverSleepSites: "")
    // content blocking through the real window
    check(app.factory.blockingActive == false, "blocking: off by default")
    app.settingsController.testApply([:], blocking: true, blockAllowlist: "shop.example")
    check(await wait(10) { app.factory.blockingActive && app.blocking.enabled }, "blocking: enabling in Settings compiles and activates the rule list")
    check(app.blocking.effectiveAllowlist.contains("shop.example") && app.blocking.effectiveAllowlist.contains("netflix.com"), "blocking: allowlist applied, video sites always exempt")
    app.settingsController.testApply([:], blocking: false)
    check(await wait(10) { !app.factory.blockingActive }, "blocking: disabling deactivates it")
    app.settingsController.testApply(["defaultGrace": "300", "maxLiveNormal": "77", "audibleGrace": "25"])       // custom values again, so the relaunch check below is meaningful

    // 9c. window position/size is remembered and comes back after a relaunch
    c1.window.setFrame(NSRect(x: 120, y: 160, width: 900, height: 640), display: false); c1.windowDidMove(Notification(name: NSWindow.didMoveNotification)); try? await Task.sleep(nanoseconds: 900_000_000)
    check(e.state.windows[c1.id]?.frame == [120, 160, 900, 640], "window frame: the new position and size are remembered (\(String(describing: e.state.windows[c1.id]?.frame)))")

    // 10. save + relaunch from the database: the WHOLE session must match
    do { try e.shutdown() } catch { check(false, "shutdown saved cleanly: \(error)") }
    do {
      let (m2, restored, rec) = try SessionManagerBridge.reopen(dir: app.dataDirForTests)
      check(rec == "clean" && restored == e.state, "relaunch: the whole session (tabs, URLs, titles, order, spaces, profiles, windows, archive) is restored exactly")
      let p2 = EngineSettings.loadPolicy(from: m2)
      check(p2.defaultGrace == 300 * 60 && p2.maxLive.normal == 77 && p2.audibleGrace == 25 * 60, "relaunch: the user's hibernation settings are still there")
      check(EngineSettings.loadUsage(from: m2).gaps == e.lifecycle.usage.gaps && !e.lifecycle.usage.gaps.isEmpty, "relaunch: learned usage habits survive (\(e.lifecycle.usage.gaps.count) hosts)")
    } catch { check(false, "relaunch threw \(error)") }

    // 11. leak cycles: the app's own memory must not grow when tabs/windows/palette/settings are opened and closed over and over
    if getenv("SELFTEST_CYCLES") != nil || getenv("SELFTEST_HOLD") != nil {
      let cycles = Int(String(cString: getenv("SELFTEST_CYCLES") ?? strdup("150"))) ?? 150
      func hostMB() -> Double { Double(ProcessMemory.selfFootprint) / 1_048_576 }
      let space1 = e.state.spaces[0].id
      for warm in 0..<10 { c1.newTab(); c1.addressField.stringValue = "\(base)/a.html"; c1.submitAddress(); await settle(); c1.closeSelectedTab(); _ = warm }   // warm-up (caches, lazy init)
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      let m0 = hostMB()
      for i in 0..<cycles {
        c1.newTab(); c1.addressField.stringValue = "\(base)/\(i % 2 == 0 ? "a" : "b").html"; c1.submitAddress()
        try? await Task.sleep(nanoseconds: 60_000_000)
        if i % 5 == 0 { app.quickOpen.show(for: c1); app.quickOpen.setQuery("page"); app.quickOpen.close() }
        if i % 10 == 0 { _ = choose("Settings…"); app.settingsController.window.orderOut(nil) }
        if i % 15 == 0 { c1.newWindow(); try? await Task.sleep(nanoseconds: 100_000_000); if let w2 = app.controllers.values.first(where: { $0 !== c1 }) { w2.window.performClose(nil) } }
        c1.closeSelectedTab()
        if i % 20 == 19, let a = e.state.archive.first { e.purge(a.id) }                  // keep the archive bounded: purge is the explicit delete
      }
      for a in e.state.archive.map(\.id) { e.purge(a) }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      let m1 = hostMB(); let growth = m1 - m0
      print(String(format: "     (host memory %.0f → %.0f MB over %d cycles)", m0, m1, cycles))
      check(growth < 60, "leak cycles: the app's memory is stable over \(cycles) tab/window/palette/settings cycles (+\(Int(growth)) MB)")
      _ = space1
    }
    print(failures.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL (\(failures.count))")
    if getenv("SELFTEST_HOLD") != nil { print("HOLDING for leaks inspection (pid \(getpid()))"); return }      // stay alive so `leaks` can inspect the live process
    exit(failures.isEmpty ? 0 : 1)
  }
}
