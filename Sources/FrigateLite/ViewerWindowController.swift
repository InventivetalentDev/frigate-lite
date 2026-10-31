import AppKit

/// Owns the camera window and the single refresh loop.
///
/// The loop is the only thing that ever touches the screen: every `1 / fps` seconds it fetches
/// `latest.jpg` for each visible camera in parallel (sized to the tile), decodes them off the
/// main thread, then hands all of them to `MosaicView.apply` in one commit. When the window is
/// hidden, minimised, fully covered, or the screen is locked/asleep, the loop stops entirely.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    let mosaic = MosaicView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    private let settings = Settings.shared

    private var client: FrigateClient?
    private var config: FrigateConfig?
    private var focused: String?
    private var loop: Task<Void, Never>?
    private var failedTicks = 0

    private var windowVisible = true
    private var screenAsleep = false
    private var screenLocked = false
    private var shouldPoll: Bool {
        // `-debugAlwaysPoll YES` (dev only): keep refreshing while hidden, for soak tests.
        UserDefaults.standard.bool(forKey: "debugAlwaysPoll") || (windowVisible && !screenAsleep && !screenLocked)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Frigate Lite"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        // Frames are sRGB. With an sRGB window, Core Animation uses them without a per-frame
        // colour conversion on the main thread; the window server matches the finished
        // window to the display on the GPU instead.
        window.colorSpace = .sRGB
        window.minSize = NSSize(width: 320, height: 200)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = mosaic
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("FrigateLiteMain") { window.center() }
        window.setFrameAutosaveName("FrigateLiteMain")
        super.init(window: window)
        window.delegate = self
        window.makeFirstResponder(mosaic)

        mosaic.showLabels = settings.showLabels
        mosaic.onSelect = { [weak self] name in self?.focus(name) }
        mosaic.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        applyWindowLevel()
        observeSystem()
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Loop

    /// Drops the connection and starts over (after Settings changed, or ⌘R).
    func reconnect() {
        client?.invalidate()
        client = nil
        config = nil
        restartLoop()
    }

    private func restartLoop() {
        loop?.cancel()
        loop = nil
        guard shouldPoll else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            if config == nil {
                if settings.baseURL.isEmpty {
                    mosaic.showMessage("Set your Frigate URL in Settings (⌘,)")
                    return // Settings → Save restarts the loop
                }
                do {
                    try await connect()
                } catch {
                    if Task.isCancelled { return }
                    let reason = "Can't load cameras from \(settings.baseURL)\n\n\(FrigateClient.describe(error))"
                    switch error as? FrigateError {
                    case .loginRejected?, .unauthorized?, .badURL?:
                        // Only a settings change can fix these. Retrying a wrong password
                        // would also trip Frigate's failed-login lockout for this IP.
                        client?.invalidate()
                        client = nil
                        mosaic.showMessage(reason)
                        return // Settings → Save restarts the loop
                    default:
                        mosaic.showMessage(reason + "\n\nRetrying every 10 s · Settings: ⌘,")
                        try? await Task.sleep(for: .seconds(10))
                        continue
                    }
                }
            }
            let started = ContinuousClock.now
            await tick()
            try? await Task.sleep(until: started + .seconds(currentInterval), clock: .continuous)
        }
    }

    private func connect() async throws {
        client?.invalidate()
        client = nil
        let url = settings.baseURL
        mosaic.showMessage("Connecting to \(url)…")
        let newClient = try FrigateClient(baseURL: url, username: settings.username,
                                          password: settings.password,
                                          allowSelfSigned: settings.allowSelfSigned)
        client = newClient
        let cfg = try await newClient.loadConfig()
        guard !Task.isCancelled else { throw CancellationError() }
        config = cfg
        failedTicks = 0
        mosaic.showMessage(nil)
        applyCameraSelection()
        if let last = settings.lastFocused, gridCameras.contains(where: { $0.name == last }) {
            focused = last
            mosaic.setFocus(last)
        }
        updateTitle()
    }

    private func tick() async {
        guard let client else { return }
        let targets = currentTargets()
        guard !targets.isEmpty else { return }
        let quality = settings.jpegQuality

        let updates = await withTaskGroup(of: (String, TileUpdate).self) { group in
            for (camera, height) in targets {
                group.addTask {
                    do {
                        let frame = try await client.frame(camera: camera.name, height: height, quality: quality)
                        guard let image = ImageDecoder.decode(frame.data, targetHeight: height) else {
                            return (camera.name, .failed("Couldn't decode the image."))
                        }
                        return (camera.name, .image(image, offline: frame.offline))
                    } catch {
                        return (camera.name, .failed(FrigateClient.describe(error)))
                    }
                }
            }
            var out: [String: TileUpdate] = [:]
            for await (name, update) in group { out[name] = update }
            return out
        }
        guard !Task.isCancelled else { return }
        mosaic.apply(updates)

        // If every camera keeps failing, Frigate is probably down or restarting: go back to
        // the connect step, which reloads the camera list and retries slowly.
        let allFailed = updates.values.allSatisfy { if case .failed = $0 { return true } else { return false } }
        failedTicks = allFailed ? failedTicks + 1 : 0
        if failedTicks >= 5 { config = nil }
    }

    private var currentInterval: Double {
        if let f = focused, let camera = camera(named: f) {
            return 1 / min(settings.focusFPS, max(camera.fps, 1))
        }
        return 1 / settings.gridFPS
    }

    private func currentTargets() -> [(Camera, Int)] {
        if let f = focused, let camera = camera(named: f) {
            return [(camera, mosaic.pixelHeight(for: f))]
        }
        return gridCameras.map { ($0, mosaic.pixelHeight(for: $0.name)) }
    }

    // MARK: Camera selection

    private func camera(named name: String) -> Camera? {
        if name == "birdseye", let b = config?.birdseye { return b }
        return config?.cameras.first { $0.name == name }
    }

    /// Cameras the current group contains, before the user's "Show Cameras" choices.
    private var groupCameras: [Camera] {
        guard let config else { return [] }
        switch settings.group {
        case Settings.birdseyeGroup:
            return config.birdseye.map { [$0] } ?? []
        case let name where !name.isEmpty:
            if let group = config.groups.first(where: { $0.name == name }) {
                let members = Set(group.cameras)
                return config.cameras.filter { members.contains($0.name) }
            }
            fallthrough
        default:
            return config.cameras.filter(\.onDashboard)
        }
    }

    /// Cameras in the grid: the current group minus hidden ones.
    private var gridCameras: [Camera] {
        let hidden = settings.hiddenCameras
        return groupCameras.filter { !hidden.contains($0.name) }
    }

    private func applyCameraSelection() {
        let cams = gridCameras
        mosaic.setCameras(cams)
        if let f = focused, !cams.contains(where: { $0.name == f }) { focused = nil }
        if config != nil && cams.isEmpty {
            mosaic.showMessage("No cameras in this view.\nPick another group or show cameras from the View menu.")
        } else if config != nil {
            mosaic.showMessage(nil)
        }
        updateTitle()
    }

    func focus(_ name: String?) {
        focused = name
        settings.lastFocused = name
        mosaic.setFocus(name)
        updateTitle()
        restartLoop() // fetch the new view right away, at its new size
    }

    private func focusRelative(_ step: Int) {
        let names = gridCameras.map(\.name)
        guard !names.isEmpty else { return }
        let current = focused.flatMap { names.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        focus(names[(current + step + names.count) % names.count])
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 53, 49: // esc, space
            if focused != nil { focus(nil) }
            return true
        case 123: focusRelative(-1); return true // left
        case 124: focusRelative(1); return true // right
        default: break
        }
        if let ch = event.charactersIgnoringModifiers, let digit = Int(ch) {
            let index = digit == 0 ? 9 : digit - 1
            let names = gridCameras.map(\.name)
            if index < names.count { focus(names[index]) }
            return true
        }
        return false
    }

    private func updateTitle() {
        guard let window else { return }
        if let f = focused, let camera = camera(named: f) {
            window.title = camera.title
            let fps = min(settings.focusFPS, max(camera.fps, 1))
            window.subtitle = "\(Settings.fpsLabel(fps)) · Esc for grid · ← → to switch"
        } else {
            window.title = groupTitle(settings.group)
            let count = config == nil ? "" : " · \(gridCameras.count) cameras"
            window.subtitle = Settings.fpsLabel(settings.gridFPS) + count + " · click a camera to focus"
        }
    }

    private func groupTitle(_ group: String) -> String {
        switch group {
        case "": return "All Cameras"
        case Settings.birdseyeGroup: return "Birdseye"
        default: return FrigateConfig.prettify(group)
        }
    }

    // MARK: Pausing

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = true; self?.restartLoop() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = false; self?.restartLoop() }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true; self?.restartLoop() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false; self?.restartLoop() }
        }
        // Occlusion covers "fully behind other windows" and "on another Space". Hide and
        // minimise are also handled explicitly, so pausing never depends on occlusion alone.
        let nc = NotificationCenter.default
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }

    private func updateVisibility() {
        guard let window else { return }
        let visible = !NSApp.isHidden && !window.isMiniaturized && window.occlusionState.contains(.visible)
        guard visible != windowVisible else { return }
        windowVisible = visible
        restartLoop() // stops when hidden; refreshes immediately when shown again
    }

    // MARK: Window options

    private func applyWindowLevel() {
        window?.level = settings.alwaysOnTop ? .floating : .normal
    }

    // MARK: View menu (rebuilt each time it opens, so it always shows the current state)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateViewMenu(menu)
    }

    func populateViewMenu(_ menu: NSMenu) {
        menu.addItem(ActionItem("Show Grid", state: focused == nil) { [weak self] in self?.focus(nil) })

        let cams = gridCameras
        if !cams.isEmpty {
            let focusMenu = NSMenu()
            for (i, cam) in cams.enumerated() {
                let key = i < 9 ? String(i + 1) : (i == 9 ? "0" : "")
                focusMenu.addItem(ActionItem(cam.title, key: key, state: focused == cam.name) { [weak self] in
                    self?.focus(cam.name)
                })
            }
            menu.addItem(submenu: "Focus Camera", focusMenu)
        }
        menu.addItem(.separator())

        if let config {
            let groupMenu = NSMenu()
            let current = settings.group
            groupMenu.addItem(ActionItem("All Cameras", state: current == "") { [weak self] in self?.setGroup("") })
            for g in config.groups {
                groupMenu.addItem(ActionItem(FrigateConfig.prettify(g.name), state: current == g.name) { [weak self] in
                    self?.setGroup(g.name)
                })
            }
            if config.birdseye != nil {
                groupMenu.addItem(.separator())
                groupMenu.addItem(ActionItem("Birdseye (one combined stream)", state: current == Settings.birdseyeGroup) { [weak self] in
                    self?.setGroup(Settings.birdseyeGroup)
                })
            }
            menu.addItem(submenu: "Camera Group", groupMenu)

            let showMenu = NSMenu()
            let hidden = settings.hiddenCameras
            for cam in groupCameras where cam.name != "birdseye" {
                showMenu.addItem(ActionItem(cam.title, state: !hidden.contains(cam.name)) { [weak self] in
                    self?.toggleHidden(cam.name)
                })
            }
            if !showMenu.items.isEmpty { menu.addItem(submenu: "Show Cameras", showMenu) }
            menu.addItem(.separator())
        }

        let gridMenu = NSMenu()
        for fps in Settings.gridFPSOptions {
            gridMenu.addItem(ActionItem(Settings.fpsLabel(fps), state: settings.gridFPS == fps) { [weak self] in
                self?.settings.gridFPS = fps
                self?.updateTitle()
                self?.restartLoop()
            })
        }
        menu.addItem(submenu: "Grid Refresh Rate", gridMenu)

        let focusRate = NSMenu()
        for fps in Settings.focusFPSOptions {
            focusRate.addItem(ActionItem(Settings.fpsLabel(fps), state: settings.focusFPS == fps) { [weak self] in
                self?.settings.focusFPS = fps
                self?.updateTitle()
                self?.restartLoop()
            })
        }
        focusRate.addItem(.separator())
        let note = NSMenuItem(title: "Capped at each camera's detect FPS", action: nil, keyEquivalent: "")
        note.isEnabled = false
        focusRate.addItem(note)
        menu.addItem(submenu: "Focused Refresh Rate", focusRate)

        let qualityMenu = NSMenu()
        for q in Settings.qualityOptions {
            qualityMenu.addItem(ActionItem(q.label, state: settings.jpegQuality == q.value) { [weak self] in
                self?.settings.jpegQuality = q.value
            })
        }
        menu.addItem(submenu: "Image Quality", qualityMenu)
        menu.addItem(.separator())

        menu.addItem(ActionItem("Show Camera Names", key: "l", state: settings.showLabels) { [weak self] in
            guard let self else { return }
            settings.showLabels.toggle()
            mosaic.showLabels = settings.showLabels
        })
        menu.addItem(ActionItem("Float on Top", key: "t", modifiers: [.command, .option], state: settings.alwaysOnTop) { [weak self] in
            guard let self else { return }
            settings.alwaysOnTop.toggle()
            applyWindowLevel()
        })
        menu.addItem(ActionItem("Reload Cameras", key: "r") { [weak self] in self?.reconnect() })
        menu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
    }

    private func setGroup(_ group: String) {
        settings.group = group
        focused = nil
        mosaic.setFocus(nil)
        applyCameraSelection()
        restartLoop()
    }

    private func toggleHidden(_ name: String) {
        var hidden = settings.hiddenCameras
        if hidden.contains(name) { hidden.remove(name) } else { hidden.insert(name) }
        settings.hiddenCameras = hidden
        applyCameraSelection()
        restartLoop()
    }
}

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         state: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        self.state = state ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

extension NSMenu {
    func addItem(submenu title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        addItem(item)
    }
}
