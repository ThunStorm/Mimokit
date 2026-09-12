import Foundation
import SQLite3

struct AccountCredentials: Sendable, Equatable {
    let passToken: String
    let userId: String
    let cUserId: String
}

protocol CredentialReading: Sendable {
    func loadAccountCredentials() throws -> AccountCredentials
}

/// Reads Xiaomi account partition cookies (read-only). Tokens stay in memory only.
/// Copies the SQLite file first so a live MiMo process locking WAL cannot block reads.
struct CredentialSource: CredentialReading {
    let cookiesFileURL: URL

    init(cookiesFileURL: URL? = ProcessLocator.accountCookiesURL()) {
        self.cookiesFileURL = cookiesFileURL ?? URL(fileURLWithPath: "/dev/null")
    }

    func loadAccountCredentials() throws -> AccountCredentials {
        guard FileManager.default.fileExists(atPath: cookiesFileURL.path) else {
            throw UsageError.authExpired
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimometer-cookies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("Cookies")
        do {
            try copyCookieStore(to: tempDB)
        } catch {
            // Fall back to opening the original if copy fails.
            return try readCredentials(from: cookiesFileURL)
        }
        return try readCredentials(from: tempDB)
    }

    private func copyCookieStore(to destination: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: cookiesFileURL, to: destination)
        // Also copy -wal / -shm if present so we see the latest committed rows.
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: cookiesFileURL.path + suffix)
            if fm.fileExists(atPath: side.path) {
                let sideDest = URL(fileURLWithPath: destination.path + suffix)
                try? fm.copyItem(at: side, to: sideDest)
            }
        }
    }

    private func readCredentials(from dbURL: URL) throws -> AccountCredentials {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw UsageError.authExpired
        }
        defer { sqlite3_close_v2(db) }

        // Prefer account.xiaomi.com; fall back to any xiaomi.com host.
        let sql = """
        SELECT name, value FROM cookies
        WHERE name IN ('passToken', 'userId', 'cUserId')
          AND host_key LIKE '%xiaomi.com'
          AND length(value) > 0
        ORDER BY
          CASE WHEN host_key LIKE '%account.xiaomi.com' THEN 0 ELSE 1 END,
          length(value) DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageError.authExpired
        }
        defer { sqlite3_finalize(statement) }

        var found: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 0),
                  let valueC = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: nameC)
            if found[name] == nil {
                found[name] = String(cString: valueC)
            }
        }

        guard let passToken = found["passToken"], !passToken.isEmpty,
              let userId = found["userId"], !userId.isEmpty,
              let cUserId = found["cUserId"], !cUserId.isEmpty
        else {
            throw UsageError.authExpired
        }

        return AccountCredentials(passToken: passToken, userId: userId, cUserId: cUserId)
    }
}
