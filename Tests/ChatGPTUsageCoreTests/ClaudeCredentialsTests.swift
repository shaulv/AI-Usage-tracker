import CommonCrypto
import Foundation
import SQLite3
import XCTest
@testable import ChatGPTUsageCore

/// Multi-source Claude credential loading: desktop OAuth token cache, Claude Code
/// JSON/Keychain credentials, Claude Desktop cookies, Chrome snapshot cookies,
/// and Keychain access denial vs missing item semantics. All tests use /tmp and
/// an injected Keychain stub; none touch the real home directory or Keychain.
final class ClaudeCredentialsTests: XCTestCase {

    // MARK: - Helpers

    private func encryptAES128CBC(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: 16)
        let outCapacity = plaintext.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        let keyCount = key.count
        let plaintextCount = plaintext.count
        var outLength = 0
        let status = plaintext.withUnsafeBytes { inBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    out.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyCount,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, plaintextCount,
                            outBytes.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TestError.cryptoFailed }
        return Data("v10".utf8) + out.prefix(outLength)
    }

    private func encryptSafeStorage(_ text: String, password: String) throws -> String {
        let key = ClaudeDesktopSessionSource.deriveKey(password: password)
        let blob = try encryptAES128CBC(Data(text.utf8), key: key)
        return blob.base64EncodedString()
    }

    private func encryptChromiumCookie(_ text: String, password: String) throws -> Data {
        let key = ClaudeDesktopSessionSource.deriveKey(password: password)
        let prefixed = Data(repeating: 0x61, count: 32) + Data(text.utf8)
        return try encryptAES128CBC(prefixed, key: key)
    }

    private func makeCookiesDB(
        at url: URL,
        rows: [(host: String, name: String, blob: Data, expires: Int64)],
        walMode: Bool = false
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw TestError.sqliteFailed
        }
        defer { sqlite3_close(db) }
        if walMode {
            _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        }
        guard sqlite3_exec(
            db,
            "CREATE TABLE cookies(host_key TEXT, name TEXT, encrypted_value BLOB, expires_utc INTEGER);",
            nil, nil, nil
        ) == SQLITE_OK else {
            throw TestError.sqliteFailed
        }
        let sql = "INSERT INTO cookies(host_key, name, encrypted_value, expires_utc) VALUES(?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TestError.sqliteFailed
        }
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            sqlite3_bind_text(stmt, 1, row.host, -1, testTransient)
            sqlite3_bind_text(stmt, 2, row.name, -1, testTransient)
            _ = row.blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(row.blob.count), testTransient)
            }
            sqlite3_bind_int64(stmt, 4, row.expires)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw TestError.sqliteFailed
            }
            sqlite3_reset(stmt)
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "claude-cred-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private enum TestError: Error {
        case cryptoFailed
        case sqliteFailed
    }

    private let testTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let fixedNow = Date(timeIntervalSince1970: 1_794_600_000)

    // MARK: - 1. SafeStorage string decryption

    func test_decryptSafeStorageString_roundTripsWithoutStrippingPrefix() throws {
        let password = "test-claude-safe-storage"
        let key = ClaudeDesktopSessionSource.deriveKey(password: password)
        let blob = try encryptAES128CBC(Data("{\"ok\":true}".utf8), key: key)

        XCTAssertEqual(ClaudeDesktopSessionSource.decryptSafeStorageString(blob, key: key), "{\"ok\":true}")
        XCTAssertNil(ClaudeDesktopSessionSource.decryptSafeStorageString(Data("v99junk".utf8), key: key))
        XCTAssertNil(ClaudeDesktopSessionSource.decryptSafeStorageString(Data("v10".utf8), key: key))
        XCTAssertNil(ClaudeDesktopSessionSource.decryptSafeStorageString(blob, key: Data()))
    }

    // MARK: - 2. Claude Desktop oauth:tokenCacheV2

    func test_load_prefersClaudeDesktopOAuthTokenCacheV2OverCookies() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let futureMs = (fixedNow.timeIntervalSince1970 + 3600) * 1000
        let cachePayload: [String: Any] = [
            "acct:u1|c1:org1:https://api-staging.anthropic.com:user:inference user:profile": [
                "token": "staging-token",
                "expiresAt": futureMs + 9000,
            ],
            "acct:u1|c2:org1:https://api.anthropic.com:user:inference": [
                "token": "inference-only-token",
                "expiresAt": futureMs + 5000,
            ],
            "acct:u1|c3:org1:https://api.anthropic.com:user:inference user:profile user:file_upload": [
                "token": "prod-profile-token",
                "expiresAt": futureMs,
            ],
            "acct:u1|c4:org1:https://api.anthropic.com:user:profile": NSNull(),
        ]
        let cacheJSON = String(data: try JSONSerialization.data(withJSONObject: cachePayload), encoding: .utf8)!
        let encryptedV2 = try encryptSafeStorage(cacheJSON, password: "desktop-secret")

        let configURL = dir.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: ["oauth:tokenCacheV2": encryptedV2]).write(to: configURL)

        let source = ClaudeDesktopSessionSource(
            configFileURL: configURL,
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: dir.appending(path: ".credentials.json"),
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { service in
                service == "Claude Safe Storage" ? .found("desktop-secret") : .notFound
            },
            now: { self.fixedNow }
        )

        let session = try source.load()
        XCTAssertEqual(session.accessToken, "prod-profile-token")
    }

    // MARK: - 3. Claude Desktop oauth:tokenCache (v1) fallback

    func test_load_fallsBackToOAuthTokenCacheV1WhenV2Absent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let futureMs = (fixedNow.timeIntervalSince1970 + 7200) * 1000
        let cachePayload = [
            "acct:u1|c1:org1:https://api.anthropic.com:user:profile": [
                "token": "v1-token",
                "expiresAt": futureMs,
            ]
        ]
        let cacheJSON = String(data: try JSONSerialization.data(withJSONObject: cachePayload), encoding: .utf8)!
        let encryptedV1 = try encryptSafeStorage(cacheJSON, password: "desktop-secret")

        let configURL = dir.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: ["oauth:tokenCache": encryptedV1]).write(to: configURL)

        let source = ClaudeDesktopSessionSource(
            configFileURL: configURL,
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: dir.appending(path: ".credentials.json"),
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { service in
                service == "Claude Safe Storage" ? .found("desktop-secret") : .notFound
            },
            now: { self.fixedNow }
        )

        XCTAssertEqual(try source.load().accessToken, "v1-token")
    }

    // MARK: - 4. Expired / revoked OAuth cache falls through to Claude Code credentials

    func test_load_skipsRevokedOAuthCacheAndUsesClaudeCodeFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cachePayload: [String: Any] = [
            "acct:u1|c1:org1:https://api.anthropic.com:user:profile": [
                "token": "revoked-zero-expiry",
                "expiresAt": 0,
            ],
            "acct:u1|c2:org1:https://api.anthropic.com:user:profile": [
                "token": "past-token",
                "expiresAt": (fixedNow.timeIntervalSince1970 - 3600) * 1000,
            ],
        ]
        let encryptedV2 = try encryptSafeStorage(
            String(data: try JSONSerialization.data(withJSONObject: cachePayload), encoding: .utf8)!,
            password: "desktop-secret"
        )
        let configURL = dir.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: ["oauth:tokenCacheV2": encryptedV2]).write(to: configURL)

        let cliURL = dir.appending(path: ".credentials.json")
        let cliJSON: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "cli-file-token",
                "expiresAt": (fixedNow.timeIntervalSince1970 + 3600) * 1000,
                "scopes": ["user:inference", "user:profile"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: cliJSON).write(to: cliURL)

        let source = ClaudeDesktopSessionSource(
            configFileURL: configURL,
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: cliURL,
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { service in
                service == "Claude Safe Storage" ? .found("desktop-secret") : .notFound
            },
            now: { self.fixedNow }
        )

        XCTAssertEqual(try source.load().accessToken, "cli-file-token")
    }

    // MARK: - 5. Expired file + valid Claude Code Keychain item

    func test_load_usesClaudeCodeKeychainCredentialsWhenFileExpired() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cliURL = dir.appending(path: ".credentials.json")
        let expiredCLI: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "stale-july-token",
                "expiresAt": (fixedNow.timeIntervalSince1970 - 1000) * 1000,
                "scopes": ["user:profile"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: expiredCLI).write(to: cliURL)

        let freshKeychainPayload = String(data: try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "keychain-cli-token",
                "expiresAt": (fixedNow.timeIntervalSince1970 + 3600) * 1000,
                "scopes": ["user:profile", "user:inference"],
            ]
        ]), encoding: .utf8)!

        let source = ClaudeDesktopSessionSource(
            configFileURL: dir.appending(path: "config.json"),
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: cliURL,
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { service in
                service == "Claude Code-credentials" ? .found(freshKeychainPayload) : .notFound
            },
            now: { self.fixedNow }
        )

        XCTAssertEqual(try source.load().accessToken, "keychain-cli-token")
    }

    // MARK: - 6. Deprioritizes Claude Code token missing user:profile below valid Cookies

    func test_load_prefersCookieSessionOverClaudeCodeTokenMissingProfileScope() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cliURL = dir.appending(path: ".credentials.json")
        let cliJSON: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "inference-only-cli-token",
                "expiresAt": (fixedNow.timeIntervalSince1970 + 3600) * 1000,
                "scopes": ["user:file_upload", "user:inference", "user:mcp_servers"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: cliJSON).write(to: cliURL)

        let chromeDB = dir.appending(path: "ChromeCookies")
        try makeCookiesDB(at: chromeDB, rows: [
            (".claude.ai", "sessionKey", try encryptChromiumCookie("chrome-sk", password: "chrome-secret"), 0),
            (".claude.ai", "lastActiveOrg", try encryptChromiumCookie("org-chrome", password: "chrome-secret"), 0),
        ])

        let source = ClaudeDesktopSessionSource(
            configFileURL: dir.appending(path: "config.json"),
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: cliURL,
            chromeCookiesDBURL: chromeDB,
            keychainLookup: { service in
                service == "Chrome Safe Storage" ? .found("chrome-secret") : .notFound
            },
            now: { self.fixedNow }
        )

        let session = try source.load()
        XCTAssertNil(session.accessToken)
        XCTAssertEqual(session.sessionKey, "chrome-sk")
        XCTAssertEqual(session.organizationId, "org-chrome")
    }

    // MARK: - 7. Empty Claude/Cookies falls back to Chrome snapshot cookies

    func test_load_fallsBackFromEmptyClaudeCookiesToChromeSnapshotCookies() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let desktopDB = dir.appending(path: "Cookies")
        try makeCookiesDB(at: desktopDB, rows: [])

        let chromeDB = dir.appending(path: "ChromeCookies")
        let futureTicks: Int64 = 13_480_000_000_000_000
        try makeCookiesDB(at: chromeDB, rows: [
            (".claude.ai", "sessionKey", try encryptChromiumCookie("sk-ant-sid01", password: "chrome-secret"), futureTicks),
            (".claude.ai", "lastActiveOrg", try encryptChromiumCookie("org-123", password: "chrome-secret"), futureTicks),
            (".claude.ai", "cf_clearance", try encryptChromiumCookie("cf-ok", password: "chrome-secret"), futureTicks),
        ], walMode: true)

        let source = ClaudeDesktopSessionSource(
            configFileURL: dir.appending(path: "config.json"),
            cookiesDBURL: desktopDB,
            claudeCodeCredentialsURL: dir.appending(path: ".credentials.json"),
            chromeCookiesDBURL: chromeDB,
            keychainLookup: { service in
                service == "Chrome Safe Storage" ? .found("chrome-secret") : .notFound
            },
            now: { self.fixedNow }
        )

        let session = try source.load()
        XCTAssertEqual(session.sessionKey, "sk-ant-sid01")
        XCTAssertEqual(session.organizationId, "org-123")
        XCTAssertEqual(session.cfClearance, "cf-ok")
    }

    // MARK: - 8. Keychain access denial vs item not found

    func test_load_whenKeychainDeniedAndNoFallback_throwsKeychainLockedError() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appending(path: "config.json")
        let encryptedV2 = try encryptSafeStorage("{}", password: "desktop-secret")
        try JSONSerialization.data(withJSONObject: ["oauth:tokenCacheV2": encryptedV2]).write(to: configURL)

        let source = ClaudeDesktopSessionSource(
            configFileURL: configURL,
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: dir.appending(path: ".credentials.json"),
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { _ in .denied(errSecAuthFailed) },
            now: { self.fixedNow }
        )

        XCTAssertThrowsError(try source.load()) { error in
            XCTAssertEqual(
                error as? UsageProviderError,
                .notConnected("Claude credentials locked in macOS Keychain - unlock Login Keychain")
            )
        }
    }

    func test_load_whenKeychainNotFound_reportsNotSignedIn() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appending(path: "config.json")
        let encryptedV2 = try encryptSafeStorage("{}", password: "desktop-secret")
        try JSONSerialization.data(withJSONObject: ["oauth:tokenCacheV2": encryptedV2]).write(to: configURL)

        let source = ClaudeDesktopSessionSource(
            configFileURL: configURL,
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: dir.appending(path: ".credentials.json"),
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { _ in .notFound },
            now: { self.fixedNow }
        )

        XCTAssertThrowsError(try source.load()) { error in
            XCTAssertEqual(
                error as? UsageProviderError,
                .notConnected("Claude Desktop is not signed in on this Mac")
            )
        }
    }

    // MARK: - 9. Does not query Safe Storage Keychain when disk files have no Claude entries

    func test_load_skipsSafeStorageKeychainQueriesWhenFilesHaveNoClaudeEntries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let desktopDB = dir.appending(path: "Cookies")
        try makeCookiesDB(at: desktopDB, rows: [])

        let chromeDB = dir.appending(path: "ChromeCookies")
        try makeCookiesDB(at: chromeDB, rows: [
            (".example.com", "sessionKey", Data("v10abc".utf8), 0),
        ])

        final class QueriedLog: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var items: [String] = []
            func append(_ service: String) {
                lock.lock()
                items.append(service)
                lock.unlock()
            }
        }
        let queried = QueriedLog()
        let source = ClaudeDesktopSessionSource(
            configFileURL: dir.appending(path: "config.json"),
            cookiesDBURL: desktopDB,
            claudeCodeCredentialsURL: dir.appending(path: ".credentials.json"),
            chromeCookiesDBURL: chromeDB,
            keychainLookup: { service in
                queried.append(service)
                return .notFound
            },
            now: { self.fixedNow }
        )

        XCTAssertThrowsError(try source.load())
        XCTAssertFalse(queried.items.contains("Claude Safe Storage"))
        XCTAssertFalse(queried.items.contains("Chrome Safe Storage"))
    }

    // MARK: - 10. Only expired credential returns expired session

    func test_load_whenOnlyExpiredCredentialExists_returnsExpiredSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cliURL = dir.appending(path: ".credentials.json")
        let expiredCLI: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "expired-token",
                "expiresAt": (fixedNow.timeIntervalSince1970 - 300) * 1000,
                "scopes": ["user:profile"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: expiredCLI).write(to: cliURL)

        let source = ClaudeDesktopSessionSource(
            configFileURL: dir.appending(path: "config.json"),
            cookiesDBURL: dir.appending(path: "Cookies"),
            claudeCodeCredentialsURL: cliURL,
            chromeCookiesDBURL: dir.appending(path: "ChromeCookies"),
            keychainLookup: { _ in .notFound },
            now: { self.fixedNow }
        )

        let session = try source.load()
        XCTAssertTrue(session.isExpired(now: fixedNow))
        XCTAssertEqual(session.accessToken, "expired-token")
    }
}
