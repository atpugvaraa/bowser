import AppKit

@MainActor
enum MainMenu {
  static func build(target: AppDelegate) -> NSMenu {
    let main = NSMenu()
    func add(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, target t: AnyObject? = target) {
      let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.tag = tag; i.target = t; menu.addItem(i)
    }
    func submenu(_ title: String, _ build: (NSMenu) -> Void) {
      let m = NSMenu(title: title); build(m); let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.submenu = m; main.addItem(i)
    }
    submenu("Browser") { m in
      add(m, "About Browser", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
      m.addItem(.separator())
      add(m, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
      m.addItem(.separator())
      add(m, "Hide Browser", #selector(NSApplication.hide(_:)), "h", target: NSApp)
      add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
      m.addItem(.separator())
      add(m, "Quit Browser", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
    }
    submenu("File") { m in
      add(m, "New Tab", #selector(AppDelegate.newTab(_:)), "t")
      add(m, "New Window", #selector(AppDelegate.newWindow(_:)), "n")
      add(m, "New Space…", #selector(AppDelegate.newSpace(_:)), "n", [.command, .shift])
      add(m, "Open Location…", #selector(AppDelegate.focusAddress(_:)), "l")
      add(m, "Quick Open…", #selector(AppDelegate.quickOpenCommand(_:)), "k")
      m.addItem(.separator())
      add(m, "Print…", #selector(AppDelegate.printPage(_:)), "p")
      m.addItem(.separator())
      add(m, "Close Tab", #selector(AppDelegate.closeTab(_:)), "w")
      add(m, "Close Window", #selector(AppDelegate.closeWindow(_:)), "w", [.command, .shift])
      add(m, "Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift])
    }
    submenu("Edit") { m in
      add(m, "Undo", Selector(("undo:")), "z", target: nil); add(m, "Redo", Selector(("redo:")), "z", [.command, .shift], target: nil)
      m.addItem(.separator())
      add(m, "Cut", #selector(NSText.cut(_:)), "x", target: nil); add(m, "Copy", #selector(NSText.copy(_:)), "c", target: nil)
      add(m, "Paste", #selector(NSText.paste(_:)), "v", target: nil); add(m, "Select All", #selector(NSText.selectAll(_:)), "a", target: nil)
      m.addItem(.separator())
      add(m, "Find…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue, target: nil)
      add(m, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue, target: nil)
      add(m, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue, target: nil)
    }
    submenu("View") { m in
      add(m, "Reload Page", #selector(AppDelegate.reloadPage(_:)), "r")
      add(m, "Stop", #selector(AppDelegate.stopPage(_:)), ".")
      m.addItem(.separator())
      add(m, "Actual Size", #selector(AppDelegate.zoomReset(_:)), "0"); add(m, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "="); add(m, "Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-")
      m.addItem(.separator())
      add(m, "Back", #selector(AppDelegate.goBack(_:)), "[")
      add(m, "Forward", #selector(AppDelegate.goForward(_:)), "]")
      m.addItem(.separator())
      add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil)
    }
    submenu("Tabs") { m in
      add(m, "Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", .control)
      add(m, "Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift])
      m.addItem(.separator())
      for n in 1...9 { add(m, "Tab \(n)", #selector(AppDelegate.selectTabNumber(_:)), "\(n)", tag: n) }
      m.addItem(.separator())
      add(m, "Sleep Other Tabs", #selector(AppDelegate.sleepOtherTabs(_:)))
      add(m, "Memory & Tabs…", #selector(AppDelegate.showResources(_:)))
    }
    submenu("Bookmarks") { m in
      m.delegate = target
      add(m, "Bookmark This Page", #selector(AppDelegate.bookmarkPage(_:)), "d")       // static: a key equivalent must exist before the menu is ever opened
      m.addItem(.separator())
    }
    submenu("Spaces") { m in m.delegate = target; m.addItem(withTitle: "(none)", action: nil, keyEquivalent: "") }
    submenu("Window") { m in
      add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
      add(m, "Zoom", #selector(NSWindow.performZoom(_:)), target: nil)
      m.addItem(.separator()); add(m, "Show Downloads", #selector(AppDelegate.showDownloads(_:)), "j", [.command, .shift])
    }
    NSApp.windowsMenu = main.items.last?.submenu
    return main
  }
}
