import AppKit
import BrowserCore
import EngineWebKit
import Foundation

/// Drives the real UI programmatically and exits with a verdict. Run through scripts/ui-selftest.sh (serves local pages).
@MainActor
struct SelfTest {
  let app: AppDelegate; let base: String
  func run() async {
    var failures: [String] = []
    func check(_ c: Bool, _ name: String) { print(c ? "ok   \(name)" : "FAIL \(name)"); if !c { failures.append(name) } }
    func wait(_ s: Double, _ cond: @MainActor () -> Bool) async -> Bool { let end = Date().addingTimeInterval(s); while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 80_000_000) }; return cond() }
    func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }
    let e = app.engine!

    // 1. launch state
    guard let c1 = app.controllers.values.first else { print("FAIL no window at launch"); exit(1) }
    check(app.controllers.count == 1 && e.state.spaces.count == 1 && e.state.tabs.count == 1, "launch: one window, one space, one tab")
    check(c1.window.isVisible && c1.addressField.window === c1.window, "launch: window visible with an address bar")

    // 2. type an address, navigate
    c1.addressField.stringValue = "\(base)/a.html"; c1.submitAddress()
    check(await wait(15) { c1.window.title == "Page A" }, "address bar: typed URL loads, window title follows the page (\(c1.window.title))")
    check(c1.rowTitles == ["Page A"], "sidebar: row shows the page title")
    check((e.tab(c1.selected!) as? WebKitTab)?.webView?.superview != nil, "content: the web view is on screen")

    // 3. new tab
    c1.newTab(); await settle()
    check(e.state.tabs.count == 2 && c1.rowTitles.count == 2 && c1.rowTitles[1] == "New Tab", "⌘T: second tab appears (New Tab), selected")
    c1.addressField.stringValue = "\(base)/b.html"; c1.submitAddress()
    check(await wait(15) { c1.rowTitles.contains("Page B") }, "second tab navigates; sidebar shows both titles \(c1.rowTitles)")

    // 4. rejected input
    c1.addressField.stringValue = "javascript:alert(1)"; let before = e.state.tabs[c1.selected!]?.url; c1.submitAddress(); await settle()
    check(e.state.tabs[c1.selected!]?.url == before, "address bar: javascript: is refused (page unchanged)")

    // 5. tab switching + keyboard-equivalent actions
    c1.selectTab(number: 1); await settle(); check(c1.window.title == "Page A", "⌘1 selects the first tab")
    c1.selectAdjacent(+1); await settle(); check(c1.window.title == "Page B", "⌃Tab selects the next tab")

    // 6. close sleeps into the archive; reopen restores
    c1.closeSelectedTab(); await settle()
    check(e.state.tabs.count == 1 && e.state.archive.count == 1 && c1.rowTitles == ["Page A"], "⌘W: tab goes to the archive, not destroyed")
    c1.reopenClosedTab(); await settle()
    check(e.state.tabs.count == 2 && e.state.archive.isEmpty, "⇧⌘T: closed tab comes back")

    // 7. second window: a tab is shown in one window only
    c1.newWindow(); check(await wait(5) { app.controllers.count == 2 }, "⌘N: second window opens")
    let c2 = app.controllers.values.first { $0 !== c1 }!; await settle()
    let shownIn1 = c1.selected!
    c2.selectTab(shownIn1); await settle()
    check(e.state.windows[c2.id]?.selected != shownIn1, "a tab shown in window 1 is not cloned into window 2 (focus moves instead)")

    // 8. closing a window keeps its tabs (sleeps them)
    let tabsBefore = e.state.tabs.count; c2.window.performClose(nil); check(await wait(5) { app.controllers.count == 1 }, "closing a window removes only the window")
    check(e.state.tabs.count == tabsBefore, "closing a window never closes tabs (\(e.state.tabs.count) tabs kept)")

    // 9. spaces
    let sp2 = c1.createSpace(name: "Work", separateProfile: true); await settle()
    check(sp2 != nil && e.state.spaces.count == 2 && c1.space == sp2, "new space with a separate profile; window switches to it")
    check(e.state.space(sp2!)?.profile != e.state.spaces[0].profile, "the new space has its own profile (own data store)")
    c1.switchSpace(index: 0); await settle(); check(c1.rowTitles.contains("Page A"), "switching back shows the first space's tabs")

    // 10. sleeping tabs and resource view data
    c1.sleepOthers(); await settle()
    let awake = e.liveCount; check(awake >= 1, "sleep other tabs keeps the selected one awake (\(awake) awake)")

    // 11. save + relaunch from the database (lazy, state intact)
    let stateBefore = e.state
    do { try e.shutdown() } catch { check(false, "shutdown saved cleanly: \(error)") }
    do {
      let dir = app.dataDirForTests
      let (_, restored, rec) = try SessionManagerBridge.reopen(dir: dir)
      check(rec == "clean" && restored.tabs.count == stateBefore.tabs.count && restored.spaces.count == stateBefore.spaces.count && restored.windows.count == stateBefore.windows.count, "relaunch: session restored exactly (\(restored.tabs.count) tabs, \(restored.spaces.count) spaces)")
    } catch { check(false, "relaunch threw \(error)") }

    print(failures.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL (\(failures.count))")
    exit(failures.isEmpty ? 0 : 1)
  }
}
