import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Frigate Lite Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilds the form from the current settings each time, so it never shows stale values.
    func present() {
        guard let window else { return }
        let view = SettingsView { [weak self] in
            self?.window?.close()
            self?.onSave()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct SettingsView: View {
    let onSave: () -> Void

    @State private var url = Settings.shared.baseURL
    @State private var username = Settings.shared.username
    @State private var password = Settings.shared.password
    @State private var allowSelfSigned = Settings.shared.allowSelfSigned
    @State private var gridFPS = Settings.shared.gridFPS
    @State private var focusFPS = Settings.shared.focusFPS
    @State private var quality = Settings.shared.jpegQuality

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("URL", text: $url, prompt: Text("http://192.168.1.20:5000"))
                    TextField("Username", text: $username, prompt: Text("empty if no login"))
                    SecureField("Password", text: $password)
                    Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                } header: {
                    Text("Frigate server")
                } footer: {
                    Text("Port 5000: no login. Port 8971: login and HTTPS with a self-signed certificate by default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Refresh") {
                    Picker("Grid", selection: $gridFPS) {
                        ForEach(Settings.gridFPSOptions, id: \.self) { Text(Settings.fpsLabel($0)).tag($0) }
                    }
                    Picker("Focused camera", selection: $focusFPS) {
                        ForEach(Settings.focusFPSOptions, id: \.self) { Text(Settings.fpsLabel($0)).tag($0) }
                    }
                    Picker("Image quality", selection: $quality) {
                        ForEach(Settings.qualityOptions, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Save & Connect", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        // A grouped Form has no natural height, so size the window explicitly.
        .frame(width: 480, height: 480)
    }

    private func save() {
        let s = Settings.shared
        s.baseURL = url
        s.username = username
        s.setPassword(password)
        s.allowSelfSigned = allowSelfSigned
        s.gridFPS = gridFPS
        s.focusFPS = focusFPS
        s.jpegQuality = quality
        onSave()
    }
}
