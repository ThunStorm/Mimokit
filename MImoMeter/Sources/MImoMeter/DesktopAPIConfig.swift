import AppKit
import Foundation

struct DesktopAPIConfig: Equatable, Sendable {
    let api: String?
    let port: Int
    let token: String
    let pid: Int?

    var baseURL: URL? {
        if let api, let url = URL(string: api), url.host != nil {
            return url
        }
        guard port > 0, port <= 65_535 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }
}

enum DesktopAPIConfigParser {
    static func parse(data: Data) throws -> DesktopAPIConfig {
        struct Raw: Decodable {
            // MiMo may write `api` as a version number instead of a URL string.
            let api: FlexibleString?
            let port: Int?
            let token: String?
            let pid: Int?
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let token = raw.token, !token.isEmpty else {
            throw UsageError.invalidPayload
        }
        guard let port = raw.port, port > 0, port <= 65_535 else {
            throw UsageError.invalidPayload
        }
        return DesktopAPIConfig(api: raw.api?.value, port: port, token: token, pid: raw.pid)
    }

    static func load(from fileURL: URL, fileManager: FileManager = .default) throws -> DesktopAPIConfig {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw UsageError.bridgeUnavailable
        }
        let data = try Data(contentsOf: fileURL)
        return try parse(data: data)
    }
}

enum ProcessLocator {
    static let mimoBundleIdentifier = "com.xiaomi.mimo.desktop"
    static let fallbackAppPath = "/Applications/Xiaomi MiMo.app"

    static func mimoApplicationURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mimoBundleIdentifier) {
            return url
        }
        let fallback = URL(fileURLWithPath: fallbackAppPath)
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    static func mimoSupportDirectory(fileManager: FileManager = .default) -> URL? {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let support = base.appendingPathComponent("Xiaomi MiMo", isDirectory: true)
        guard fileManager.fileExists(atPath: support.path) else { return nil }
        return support
    }

    static func desktopAPIConfigURL(fileManager: FileManager = .default) -> URL? {
        mimoSupportDirectory(fileManager: fileManager)?.appendingPathComponent("desktop-api.json")
    }

    static func accountCookiesURL(fileManager: FileManager = .default) -> URL? {
        mimoSupportDirectory(fileManager: fileManager)?
            .appendingPathComponent("Partitions/xiaomi-account/Cookies", isDirectory: false)
    }
}
