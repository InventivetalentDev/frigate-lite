import Foundation
import ImageIO

struct Camera: Sendable, Hashable {
    let name: String
    let title: String
    let order: Int
    let onDashboard: Bool
    /// Detect-stream size. `latest.jpg` is cut from this stream, so it is also the useful maximum.
    let width: Int
    let height: Int
    /// Detect FPS. `latest.jpg` never changes faster than this.
    let fps: Double

    var aspect: CGFloat { width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 16.0 / 9.0 }
}

struct CameraGroup: Sendable {
    let name: String
    let order: Int
    let cameras: [String]
}

struct FrigateConfig: Sendable {
    /// All enabled cameras, sorted like Frigate's dashboard (ui.order, then name).
    let cameras: [Camera]
    let groups: [CameraGroup]
    /// Present when birdseye is enabled with restream, so `/api/birdseye/latest.jpg` works.
    let birdseye: Camera?

    /// Lenient parse: `/api/config` is large and changes between Frigate versions,
    /// so only the handful of fields we need are read and everything is optional.
    static func parse(_ data: Data) throws -> FrigateConfig {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cams = root["cameras"] as? [String: Any] else {
            throw FrigateError.badConfig
        }

        var cameras: [Camera] = []
        for (name, value) in cams {
            guard let c = value as? [String: Any] else { continue }
            if (c["enabled"] as? Bool) == false { continue }
            let ui = c["ui"] as? [String: Any]
            let detect = c["detect"] as? [String: Any]
            let friendly = (c["friendly_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            cameras.append(Camera(
                name: name,
                title: friendly ?? prettify(name),
                order: int(ui?["order"]) ?? 0,
                onDashboard: (ui?["dashboard"] as? Bool) ?? true,
                width: int(detect?["width"]) ?? 0,
                height: int(detect?["height"]) ?? 0,
                fps: Double(int(detect?["fps"]) ?? 5)
            ))
        }
        cameras.sort { ($0.order, $0.name) < ($1.order, $1.name) }

        let known = Set(cameras.map(\.name))
        var groups: [CameraGroup] = []
        for (name, value) in (root["camera_groups"] as? [String: Any]) ?? [:] {
            guard let g = value as? [String: Any] else { continue }
            var members: [String] = []
            if let list = g["cameras"] as? [String] {
                members = list
            } else if let s = g["cameras"] as? String {
                members = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            members = members.filter { known.contains($0) }
            if members.isEmpty { continue }
            groups.append(CameraGroup(name: name, order: int(g["order"]) ?? 0, cameras: members))
        }
        groups.sort { ($0.order, $0.name) < ($1.order, $1.name) }

        var birdseye: Camera?
        if let b = root["birdseye"] as? [String: Any],
           (b["enabled"] as? Bool) == true, (b["restream"] as? Bool) == true {
            birdseye = Camera(name: "birdseye", title: "Birdseye", order: 0, onDashboard: false,
                              width: int(b["width"]) ?? 1280, height: int(b["height"]) ?? 720, fps: 10)
        }

        return FrigateConfig(cameras: cameras, groups: groups, birdseye: birdseye)
    }

    static func prettify(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func int(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }
}

enum FrigateError: LocalizedError {
    case badURL
    case badConfig
    case http(Int)
    case unauthorized
    case loginRejected

    var errorDescription: String? {
        switch self {
        case .badURL: return "The Frigate URL is not valid."
        case .badConfig: return "Frigate's /api/config response was not understood."
        case .http(let code): return "Frigate answered HTTP \(code)."
        case .unauthorized: return "Frigate requires a login. Add username and password in Settings (⌘,)."
        case .loginRejected: return "Frigate rejected the username or password. Fix them in Settings (⌘,)."
        }
    }
}

struct FrameData: Sendable {
    let data: Data
    /// Frigate sets `X-Frigate-Offline: true` when it serves an old preview frame for a dead camera.
    let offline: Bool
}

/// Talks to Frigate's HTTP API: login, camera config, latest frames.
/// One URLSession with keep-alive connections, no cache, cookies kept in memory only.
actor FrigateClient {
    nonisolated let base: URL
    nonisolated private let session: URLSession
    private let username: String
    private let password: String
    private var needsLogin: Bool
    private var loginRejected = false
    private var loginTask: Task<Void, Error>?

    init(baseURL: String, username: String, password: String, allowSelfSigned: Bool) throws {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else {
            throw FrigateError.badURL
        }
        base = url
        self.username = username
        self.password = password
        needsLogin = !username.isEmpty

        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg,
                             delegate: TrustDelegate(selfSignedHost: allowSelfSigned ? host : nil),
                             delegateQueue: nil)
    }

    /// Must be called when the client is replaced, or the session (and its delegate) leaks.
    nonisolated func invalidate() {
        session.invalidateAndCancel()
    }

    func loadConfig() async throws -> FrigateConfig {
        try await ensureLoggedIn()
        let (data, response) = try await session.data(from: base.appendingPathComponent("api/config"))
        try check(response)
        return try FrigateConfig.parse(data)
    }

    func frame(camera: String, height: Int, quality: Int) async throws -> FrameData {
        try await ensureLoggedIn()
        var comps = URLComponents(url: base.appendingPathComponent("api/\(camera)/latest.jpg"),
                                  resolvingAgainstBaseURL: false)!
        // Current Frigate reads `height`; older (Flask-era) versions read `h`. Unknown params are ignored.
        comps.queryItems = [
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "h", value: String(height)),
            URLQueryItem(name: "quality", value: String(quality)),
        ]
        let (data, response) = try await session.data(for: URLRequest(url: comps.url!))
        try check(response)
        let offline = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Frigate-Offline") == "true"
        return FrameData(data: data, offline: offline)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401:
            if username.isEmpty { throw FrigateError.unauthorized }
            needsLogin = true // token expired; log in again on the next request
            throw FrigateError.unauthorized
        default:
            throw FrigateError.http(http.statusCode)
        }
    }

    /// Logs in once, even when a dozen frame requests ask at the same time.
    /// A rejected password is not retried until settings change, so Frigate's
    /// failed-login lockout is never triggered by this app.
    private func ensureLoggedIn() async throws {
        if loginRejected { throw FrigateError.loginRejected }
        guard needsLogin else { return }
        if let running = loginTask {
            try await running.value
            return
        }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        try await task.value
    }

    private func performLogin() async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user": username, "password": password])
        let (_, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300, 404: // 404 = "Authentication is disabled" (e.g. port 5000)
            // The JWT arrives as a cookie; the session's cookie store sends it from now on.
            needsLogin = false
        case 401, 403:
            loginRejected = true
            throw FrigateError.loginRejected
        default:
            throw FrigateError.http(status)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? FrigateError { return e.errorDescription ?? "\(e)" }
        if let e = error as? URLError {
            switch e.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                 .secureConnectionFailed:
                return "TLS certificate not trusted. Turn on “Allow self-signed certificate” in Settings (⌘,)."
            case .cannotFindHost, .dnsLookupFailed:
                return "Host not found."
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                // macOS reports a missing Local Network permission as a plain connection error.
                if isLocalNetwork(e.failingURL?.host) {
                    return "Can't connect to Frigate. If macOS didn't ask for Local Network access, "
                        + "turn it on in System Settings → Privacy & Security → Local Network."
                }
                return "Can't connect to Frigate."
            case .timedOut:
                return "Frigate didn't answer in time."
            default:
                return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Private IPv4 ranges, `.local`, and single-label host names (e.g. `frigate`).
    private nonisolated static func isLocalNetwork(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }
}

/// Accepts the self-signed certificate Frigate generates for port 8971, for the configured host only.
private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let selfSignedHost: String?

    init(selfSignedHost: String?) {
        self.selfSignedHost = selfSignedHost
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let host = selfSignedHost, space.host == host, let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum ImageDecoder {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Decodes a JPEG on the calling (background) thread into a plain 32-bit BGRA sRGB bitmap,
    /// the format Core Animation uses natively. The main thread then only swaps it into a layer.
    ///
    /// Why not hand ImageIO's CGImage to the layer directly: Core Animation sees it is backed
    /// by a JPEG and decodes it *again* during the commit, on the main thread. Drawing it into
    /// our own bitmap here detaches it from the JPEG.
    ///
    /// If the frame is much taller than needed (an older Frigate that ignores `height`), JPEG
    /// subsampling decodes at 1/2, 1/4 or 1/8 size directly, about 9x cheaper than ImageIO's
    /// thumbnail path (full decode plus CPU resample). Remaining scaling happens on the GPU.
    static func decode(_ data: Data, targetHeight: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                                                           [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            var factor = 1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let height = props[kCGImagePropertyPixelHeight] as? Int {
                while factor < 8 && height / (factor * 2) >= targetHeight { factor *= 2 }
            }
            guard let jpeg = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceSubsampleFactor: factor] as CFDictionary) else { return nil }

            let w = jpeg.width, h = jpeg.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(jpeg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
    }
}
