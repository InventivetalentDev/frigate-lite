import Foundation
import Security

/// User preferences. Everything lives in UserDefaults except the password (Keychain).
///
/// Any key can be overridden for one run from the command line without being saved,
/// e.g. `FrigateLite -baseURL http://127.0.0.1:5055 -gridFPS 2` (UserDefaults argument domain).
@MainActor
final class Settings {
    static let shared = Settings()

    static let gridFPSOptions: [Double] = [0.2, 0.5, 1, 2, 5]
    static let focusFPSOptions: [Double] = [1, 2, 5, 10]
    static let qualityOptions: [(label: String, value: Int)] = [("Low", 50), ("Medium", 70), ("High", 85)]
    static let birdseyeGroup = "__birdseye"

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "gridFPS": 1.0,
            "focusFPS": 5.0,
            "jpegQuality": 70,
            "showLabels": true,
            "allowSelfSigned": false,
            "alwaysOnTop": false,
        ])
    }

    /// Normalised base URL string, e.g. "http://192.168.1.20:5000". Empty when unset.
    var baseURL: String {
        get { d.string(forKey: "baseURL") ?? "" }
        set { d.set(Settings.normalize(url: newValue), forKey: "baseURL") }
    }

    var username: String {
        get { d.string(forKey: "username") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "username") }
    }

    /// `FRIGATELITE_PASSWORD` in the environment wins (handy for scripted runs), then the Keychain.
    var password: String {
        if let env = ProcessInfo.processInfo.environment["FRIGATELITE_PASSWORD"] { return env }
        guard !username.isEmpty else { return "" }
        return Keychain.get(account: username) ?? ""
    }

    func setPassword(_ password: String) {
        guard !username.isEmpty else { return }
        Keychain.set(password, account: username)
    }

    var allowSelfSigned: Bool {
        get { d.bool(forKey: "allowSelfSigned") }
        set { d.set(newValue, forKey: "allowSelfSigned") }
    }

    var gridFPS: Double {
        get { max(0.05, d.double(forKey: "gridFPS")) }
        set { d.set(newValue, forKey: "gridFPS") }
    }

    var focusFPS: Double {
        get { max(0.05, d.double(forKey: "focusFPS")) }
        set { d.set(newValue, forKey: "focusFPS") }
    }

    var jpegQuality: Int {
        get { min(95, max(10, d.integer(forKey: "jpegQuality"))) }
        set { d.set(newValue, forKey: "jpegQuality") }
    }

    var showLabels: Bool {
        get { d.bool(forKey: "showLabels") }
        set { d.set(newValue, forKey: "showLabels") }
    }

    var alwaysOnTop: Bool {
        get { d.bool(forKey: "alwaysOnTop") }
        set { d.set(newValue, forKey: "alwaysOnTop") }
    }

    /// "" = all dashboard cameras, `birdseyeGroup` = Frigate's birdseye, otherwise a camera group name.
    var group: String {
        get { d.string(forKey: "group") ?? "" }
        set { d.set(newValue, forKey: "group") }
    }

    var hiddenCameras: Set<String> {
        get { Set(d.stringArray(forKey: "hiddenCameras") ?? []) }
        set { d.set(newValue.sorted(), forKey: "hiddenCameras") }
    }

    /// Camera that was focused when the app was last used; restored on launch.
    var lastFocused: String? {
        get { d.string(forKey: "lastFocused") }
        set { d.set(newValue, forKey: "lastFocused") }
    }

    static func normalize(url raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api") { s.removeLast(4) }
        return s
    }

    static func fpsLabel(_ fps: Double) -> String {
        if fps < 1 { return "1 frame every \(Int((1 / fps).rounded())) s" }
        return "\(Int(fps)) fps"
    }
}

enum Keychain {
    private static let service = "Frigate Lite"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
