import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewer: ViewerWindowController!
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        viewer = ViewerWindowController()
        NSApp.mainMenu = buildMainMenu()
        viewer.showWindow(nil)
        NSApp.activate()
        viewer.reconnect()
        if Settings.shared.baseURL.isEmpty { openSettings() }
        DebugSnapshot.scheduleIfRequested(view: viewer.mosaic)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController { [weak self] in
                self?.viewer.reconnect()
            }
        }
        settingsWindow?.present()
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Frigate Lite",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ActionItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Frigate Lite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Frigate Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: "Frigate Lite", appMenu)

        // Needed so ⌘V etc. work in the Settings text fields.
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: "Edit", editMenu)

        let viewMenu = NSMenu()
        viewMenu.delegate = viewer
        viewer.populateViewMenu(viewMenu)
        main.addItem(submenu: "View", viewMenu)

        let windowMenu = NSMenu()
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: "Window", windowMenu)
        NSApp.windowsMenu = windowMenu

        return main
    }
}

/// Development aid: `FrigateLite -snapshotPath /tmp/x.png [-snapshotDelay 6] [-snapshotQuit YES]`
/// renders the camera view to a PNG after a delay. Lets you check the output without
/// granting Screen Recording permission to a terminal.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested(view: NSView) {
        let defaults = UserDefaults.standard
        // `-debugHideAt 10 -debugUnhideAt 30`: hide/unhide the app to test that polling pauses.
        for (key, hide) in [("debugHideAt", true), ("debugUnhideAt", false)] where defaults.object(forKey: key) != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + defaults.double(forKey: key)) {
                MainActor.assumeIsolated { hide ? NSApp.hide(nil) : NSApp.unhide(nil) }
            }
        }
        guard let path = defaults.string(forKey: "snapshotPath") else { return }
        let delay = defaults.object(forKey: "snapshotDelay") == nil ? 6 : defaults.double(forKey: "snapshotDelay")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                // `-snapshotSettings YES` captures the Settings window instead.
                if defaults.bool(forKey: "snapshotSettings"),
                   let content = NSApp.windows.first(where: { $0.title == "Frigate Lite Settings" })?.contentView {
                    write(view: content, to: path)
                } else {
                    write(view: view, to: path)
                }
                if defaults.bool(forKey: "snapshotQuit") { NSApp.terminate(nil) }
            }
        }
    }

    @MainActor
    private static func write(view: NSView, to path: String) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: view.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("snapshot written: \(path)")
    }
}
