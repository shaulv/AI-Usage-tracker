import Foundation
import Security
import CommonCrypto
import SQLite3

/// The Claude Desktop session this app borrows, read-only.
///
/// Same two rules as `CodexCredentials`, restated because they are load-bearing:
///
/// 1. Never refresh anything. Claude Desktop owns its session; the OAuth refresh
///    flow belongs to Claude Code. This app reads whatever is current and shows
///    an honest "open Claude to refresh" message when it stops working.
/// 2. Never log a cookie value, never write to the cookie store. Read-only,
///    provably: the SQLite connection is opened with SQLITE_OPEN_READONLY.
///
/// Sendable because the load runs detached from the main actor on purpose:
/// the Keychain can present a consent dialog for a first-time reader, and that
/// wait must never freeze the menu-bar UI or a test host.
public struct ClaudeSession: Equatable, Sendable {
    let sessionKey: String
    let organizationId: String
    let cfClearance: String?
    /// From the cookie's `expires_utc` (100ns ticks since 1601-01-01), converted
    /// to a Unix Date. Nil when absent, which is treated as "expiry unknown".
    let expiresAt: Date?

    /// Same 60 second grace window as Codex, so clock skew cannot lock the user
    /// out of their own usage view.
    func isExpired(now: Date, grace: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(grace) < now
    }
}

/// The seam that makes every Claude credential error testable without a real
/// cookie store or Keychain item on the machine running the tests.
public protocol ClaudeSessionSource: Sendable {
    func load() throws -> ClaudeSession
}

/// Reads the `sessionKey`, `lastActiveOrg` and `cf_clearance` cookies out of
/// Claude Desktop's Chromium cookie store and decrypts them with the key macOS
/// Keychain holds under `Claude Safe Storage`.
///
/// The decrypt recipe is the standard macOS Chromium one and was verified
/// end-to-end against a live install before any Swift was written:
/// key = PBKDF2-HMAC-SHA1(keychain password, salt "saltysalt", 1003 rounds, 16B),
/// value = "v10" || AES-128-CBC(key, IV = 16 spaces, PKCS7) of (32B prefix || value).
public struct ClaudeDesktopSessionSource: ClaudeSessionSource {
    let cookiesDBURL: URL

    public init(cookiesDBURL: URL? = nil) {
        if let cookiesDBURL {
            self.cookiesDBURL = cookiesDBURL
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cookiesDBURL = home
            .appending(path: "Library/Application Support/Claude/Cookies")
    }

    public func load() throws -> ClaudeSession {
        let password = try Self.keychainPassword()
        let key = Self.deriveKey(password: password)

        var sessionKey = ""
        var organizationId = ""
        var cfClearance: String?
        var expiresAt: Date?

        try Self.forEachCookie(host: "%claude.ai%", dbPath: cookiesDBURL.path) { name, blob, expires in
            guard let value = Self.decryptCookie(blob, key: key) else { return }
            switch name {
            case "sessionKey":
                sessionKey = value
                expiresAt = Self.unixDate(fromChromiumExpires: expires)
            case "lastActiveOrg":
                organizationId = value
            case "cfClearance":
                cfClearance = value
            default:
                break
            }
        }

        guard !sessionKey.isEmpty, !organizationId.isEmpty else {
            throw UsageProviderError.notConnected("Claude Desktop is not signed in on this Mac")
        }

        return ClaudeSession(
            sessionKey: sessionKey,
            organizationId: organizationId,
            cfClearance: cfClearance,
            expiresAt: expiresAt
        )
    }

    /// Reads the `Claude Safe Storage` secret from the login Keychain. The first
    /// access from this app may show a one-time macOS approval dialog; that is
    /// the system doing its job, and the user's answer applies from then on.
    public static func keychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty
        else {
            throw UsageProviderError.notConnected("Claude Desktop is not signed in on this Mac")
        }
        return password
    }

    public static func deriveKey(password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        let passwordBytes = Array(password.utf8)
        var derived = Data(count: 16)
        let result = derived.withUnsafeMutableBytes { out -> Int32 in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    out.bindMemory(to: UInt8.self).baseAddress, out.count
                )
            }
        }
        return result == kCCSuccess ? derived : Data()
    }

    /// Decrypts one Chromium v10 cookie blob. Returns nil for any shape this
    /// code does not recognize rather than guessing — a wrong guess here would
    /// send a garbage cookie to claude.ai.
    public static func decryptCookie(_ blob: Data, key: Data) -> String? {
        guard key.count == 16 else { return nil }
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }

        let body = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var outLength = 0

        let status: CCCryptorStatus = body.withUnsafeBytes { bodyBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    out.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            bodyBytes.baseAddress, bodyBytes.count,
                            outBytes.baseAddress, outBytes.count,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }

        // Plaintext = 32-byte prefix || cookie value (padding already removed).
        guard outLength > 32 else { return nil }
        let value = out.subdata(in: 32..<outLength)
        return String(data: value, encoding: .utf8)
    }

    /// `expires_utc` is a count of MICROSECONDS since 1601-01-01T00:00:00Z
    /// (WebKit's legacy epoch). Verified against the live install: the real
    /// sessionKey value 13437063650655199 lands on 2026-10-21 with this
    /// formula — the 100ns interpretation would land in 1643.
    public static func unixDate(fromChromiumExpires ticks: Int64) -> Date? {
        guard ticks > 0 else { return nil }
        let secondsSince1601 = Double(ticks) / 1_000_000
        let secondsSinceUnixEpoch = secondsSince1601 - 11_644_473_600
        return Date(timeIntervalSince1970: secondsSinceUnixEpoch)
    }

    /// Opens the cookie database strictly read-only and walks the matching rows.
    /// The busy timeout keeps a transient lock from Claude Desktop itself from
    /// being reported to the user as a sign-in problem.
    static func forEachCookie(
        host: String,
        dbPath: String,
        visit: (String, Data, Int64) -> Void
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw UsageProviderError.notConnected("Claude Desktop is not signed in on this Mac")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT name, hex(encrypted_value), expires_utc
        FROM cookies
        WHERE host_key LIKE ? AND name IN ('sessionKey','lastActiveOrg','cf_clearance')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageProviderError.notConnected("Claude Desktop is not signed in on this Mac")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, host, -1, SQLITE_TRANSIENT)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 0),
                  let hexC = sqlite3_column_text(statement, 1)
            else { continue }
            let name = String(cString: nameC)
            let hex = String(cString: hexC)
            let expires = sqlite3_column_int64(statement, 2)
            guard let blob = Data(hexString: hex) else { continue }
            visit(name, blob, expires)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
