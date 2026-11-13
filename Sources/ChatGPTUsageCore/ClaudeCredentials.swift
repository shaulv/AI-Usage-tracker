import Foundation
import Security
import CommonCrypto
import SQLite3

/// Result of one non-interactive lookup against macOS Keychain.
///
/// Keeping "missing" distinct from "denied/locked" stops Keychain failures from
/// presenting as "not signed in".
public enum KeychainLookupResult: Equatable, Sendable {
    case found(String)
    case notFound
    case denied(OSStatus)
}

public typealias KeychainLookup = @Sendable (_ service: String) -> KeychainLookupResult

/// The Claude session this app borrows, read-only.
///
/// Supports either OAuth Bearer tokens (used by Claude Desktop's `oauth:tokenCacheV2`
/// and Claude Code against `https://api.anthropic.com/api/oauth/usage`) or
/// Chromium session cookies (`sessionKey`, `lastActiveOrg`, optional `cf_clearance`)
/// as a fallback against `claude.ai`.
///
/// Two load-bearing rules remain unchanged:
/// 1. Never refresh anything and never write to any credential store.
/// 2. Never log a token or cookie value; SQLite databases are copied to a temporary
///    snapshot before opening strictly read-only (`immutable=1`).
public struct ClaudeSession: Equatable, Sendable {
    public let sessionKey: String
    public let organizationId: String
    public let cfClearance: String?
    public let accessToken: String?
    /// From the OAuth `expiresAt` timestamp or Chromium cookie `expires_utc`.
    /// Nil when absent, which is treated as "expiry unknown".
    public let expiresAt: Date?

    public init(
        sessionKey: String,
        organizationId: String,
        cfClearance: String?,
        expiresAt: Date?
    ) {
        self.sessionKey = sessionKey
        self.organizationId = organizationId
        self.cfClearance = cfClearance
        self.accessToken = nil
        self.expiresAt = expiresAt
    }

    public init(accessToken: String, expiresAt: Date?) {
        self.sessionKey = ""
        self.organizationId = ""
        self.cfClearance = nil
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// Same 60 second grace window as Codex, so clock skew cannot lock the user
    /// out of their own usage view.
    func isExpired(now: Date, grace: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(grace) < now
    }
}

/// The seam that makes every Claude credential error testable without a real
/// cookie store, OAuth cache, or Keychain item on the machine running the tests.
public protocol ClaudeSessionSource: Sendable {
    func load() throws -> ClaudeSession
}

/// Resolves live Claude credentials read-only across local desktop/CLI/browser stores:
/// 1. Claude Desktop `config.json` (`oauth:tokenCacheV2`, then `oauth:tokenCache`),
///    decrypted with the `Claude Safe Storage` Keychain secret (AES-128-CBC `"v10"`,
///    no 32-byte cookie prefix).
/// 2. Claude Code credentials from `$CLAUDE_CONFIG_DIR/.credentials.json` or
///    `~/.claude/.credentials.json`, then Keychain service `Claude Code-credentials`
///    (tokens explicitly lacking `user:profile` are ranked behind valid browser cookies).
/// 3. Claude Desktop Chromium cookies (`~/Library/Application Support/Claude/Cookies`).
/// 4. Google Chrome `.claude.ai` cookies (`Google/Chrome/Default/Cookies`), encrypted
///    with `Chrome Safe Storage`.
public struct ClaudeDesktopSessionSource: ClaudeSessionSource {
    let configFileURL: URL
    let cookiesDBURL: URL
    let claudeCodeCredentialsURL: URL
    let chromeCookiesDBURL: URL
    let keychainLookup: KeychainLookup
    let now: @Sendable () -> Date

    public init(
        configFileURL: URL? = nil,
        cookiesDBURL: URL? = nil,
        claudeCodeCredentialsURL: URL? = nil,
        chromeCookiesDBURL: URL? = nil,
        keychainLookup: KeychainLookup? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configFileURL = configFileURL ?? home
            .appending(path: "Library/Application Support/Claude/config.json")
        self.cookiesDBURL = cookiesDBURL ?? home
            .appending(path: "Library/Application Support/Claude/Cookies")
        if let claudeCodeCredentialsURL {
            self.claudeCodeCredentialsURL = claudeCodeCredentialsURL
        } else if let overrideDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
                  !overrideDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.claudeCodeCredentialsURL = URL(fileURLWithPath: overrideDir)
                .appending(path: ".credentials.json")
        } else {
            self.claudeCodeCredentialsURL = home.appending(path: ".claude/.credentials.json")
        }
        self.chromeCookiesDBURL = chromeCookiesDBURL ?? home
            .appending(path: "Library/Application Support/Google/Chrome/Default/Cookies")
        self.keychainLookup = keychainLookup ?? { Self.defaultKeychainLookup(service: $0) }
        self.now = now
    }

    public func load() throws -> ClaudeSession {
        let currentNow = now()
        var state = ResolutionState()

        if let session = tryLoadDesktopOAuth(now: currentNow, state: &state) {
            return session
        }
        if let session = tryLoadClaudeCodeFile(now: currentNow, state: &state) {
            return session
        }
        if let session = tryLoadClaudeCodeKeychain(now: currentNow, state: &state) {
            return session
        }
        if let session = tryLoadCookieSession(
            dbURL: cookiesDBURL,
            keychainService: "Claude Safe Storage",
            now: currentNow,
            state: &state
        ) {
            return session
        }
        if let session = tryLoadCookieSession(
            dbURL: chromeCookiesDBURL,
            keychainService: "Chrome Safe Storage",
            now: currentNow,
            state: &state
        ) {
            return session
        }

        if let lowPriority = state.lowPriorityValidOAuth {
            return lowPriority
        }
        // Surface Keychain blocks before falling back to an unrelated expired file so a
        // locked Keychain is never misreported as a sign-out or stale CLI login.
        if state.sawKeychainDenied {
            throw UsageProviderError.notConnected(
                "Claude credentials locked in macOS Keychain - unlock Login Keychain"
            )
        }
        if let expired = state.expiredFallback {
            return expired
        }
        throw UsageProviderError.notConnected("Claude Desktop is not signed in on this Mac")
    }

    // MARK: - Candidate loaders

    private struct ResolutionState {
        var sawKeychainDenied = false
        var expiredFallback: ClaudeSession?
        var lowPriorityValidOAuth: ClaudeSession?
        var cachedSecrets: [String: String] = [:]

        mutating func recordExpired(_ session: ClaudeSession) {
            if expiredFallback == nil {
                expiredFallback = session
            }
        }
    }

    private func lookupKeychain(_ service: String, state: inout ResolutionState) -> String? {
        if let cached = state.cachedSecrets[service] {
            return cached
        }
        switch keychainLookup(service) {
        case .found(let secret):
            state.cachedSecrets[service] = secret
            return secret
        case .notFound:
            return nil
        case .denied:
            state.sawKeychainDenied = true
            return nil
        }
    }

    private func tryLoadDesktopOAuth(now currentNow: Date, state: inout ResolutionState) -> ClaudeSession? {
        guard let configData = try? Data(contentsOf: configFileURL),
              let configObject = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else { return nil }

        let encryptedEntries = ["oauth:tokenCacheV2", "oauth:tokenCache"]
            .compactMap { configObject[$0] as? String }
            .filter { !$0.isEmpty }
        guard !encryptedEntries.isEmpty else { return nil }

        guard let secret = lookupKeychain("Claude Safe Storage", state: &state) else { return nil }
        let key = Self.deriveKey(password: secret)

        for encoded in encryptedEntries {
            guard let blob = Data(base64Encoded: encoded),
                  let jsonText = Self.decryptSafeStorageString(blob, key: key),
                  let jsonData = jsonText.data(using: .utf8)
            else { continue }

            let candidate = Self.selectOAuthCacheSession(from: jsonData, now: currentNow)
            if let valid = candidate.valid {
                return valid
            }
            if let expired = candidate.expired {
                state.recordExpired(expired)
            }
        }
        return nil
    }

    private func tryLoadClaudeCodeFile(now currentNow: Date, state: inout ResolutionState) -> ClaudeSession? {
        guard let data = try? Data(contentsOf: claudeCodeCredentialsURL) else { return nil }
        return acceptClaudeCodePayload(data, now: currentNow, state: &state)
    }

    private func tryLoadClaudeCodeKeychain(now currentNow: Date, state: inout ResolutionState) -> ClaudeSession? {
        guard let rawJSON = lookupKeychain("Claude Code-credentials", state: &state),
              let data = rawJSON.data(using: .utf8)
        else { return nil }
        return acceptClaudeCodePayload(data, now: currentNow, state: &state)
    }

    private func acceptClaudeCodePayload(
        _ data: Data,
        now currentNow: Date,
        state: inout ResolutionState
    ) -> ClaudeSession? {
        guard let parsed = Self.parseClaudeCodeOAuth(from: data) else { return nil }
        let session = parsed.session
        if session.isExpired(now: currentNow) {
            state.recordExpired(session)
            return nil
        }
        if parsed.hasProfileScope {
            return session
        }
        if state.lowPriorityValidOAuth == nil {
            state.lowPriorityValidOAuth = session
        }
        return nil
    }

    private func tryLoadCookieSession(
        dbURL: URL,
        keychainService: String,
        now currentNow: Date,
        state: inout ResolutionState
    ) -> ClaudeSession? {
        let rows = (try? Self.readEncryptedCookies(host: "%claude.ai%", from: dbURL)) ?? []
        let names = Set(rows.map(\.name))
        guard names.contains("sessionKey"), names.contains("lastActiveOrg") else {
            return nil
        }

        guard let password = lookupKeychain(keychainService, state: &state) else { return nil }
        let key = Self.deriveKey(password: password)

        var sessionKey = ""
        var organizationId = ""
        var cfClearance: String?
        var expiresAt: Date?

        for row in rows {
            guard let value = Self.decryptCookie(row.blob, key: key), !value.isEmpty else { continue }
            switch row.name {
            case "sessionKey":
                sessionKey = value
                expiresAt = Self.unixDate(fromChromiumExpires: row.expiresUTC)
            case "lastActiveOrg":
                organizationId = value
            case "cf_clearance":
                cfClearance = value
            default:
                break
            }
        }

        guard !sessionKey.isEmpty, !organizationId.isEmpty else { return nil }
        let session = ClaudeSession(
            sessionKey: sessionKey,
            organizationId: organizationId,
            cfClearance: cfClearance,
            expiresAt: expiresAt
        )
        if session.isExpired(now: currentNow) {
            state.recordExpired(session)
            return nil
        }
        return session
    }

    // MARK: - Pure parsing helpers

    static func selectOAuthCacheSession(
        from data: Data,
        now currentNow: Date
    ) -> (valid: ClaudeSession?, expired: ClaudeSession?) {
        guard let entries = try? JSONDecoder().decode([String: OAuthCacheEntry?].self, from: data) else {
            return (nil, nil)
        }

        var bestValid: (score: Int, expiry: Date, session: ClaudeSession)?
        var bestExpired: (score: Int, expiry: Date, session: ClaudeSession)?

        for (cacheKey, maybeEntry) in entries {
            guard let entry = maybeEntry,
                  let rawToken = entry.token?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawToken.isEmpty
            else { continue }

            // Never send staging or local dev tokens to api.anthropic.com.
            if cacheKey.contains("api-staging.")
                || cacheKey.contains("://localhost")
                || cacheKey.contains("://127.0.0.1") {
                continue
            }

            let expiresAt = entry.expiresAt.map(Self.unixDate(fromEpochNumber:))
            let session = ClaudeSession(accessToken: rawToken, expiresAt: expiresAt)
            let scopeScore = cacheKey.contains("user:profile")
                ? 3
                : (cacheKey.contains("user:inference") ? 2 : 1)
            let sortDate = expiresAt ?? .distantFuture

            if session.isExpired(now: currentNow) {
                if let currentBest = bestExpired {
                    if (scopeScore, sortDate) > (currentBest.score, currentBest.expiry) {
                        bestExpired = (scopeScore, sortDate, session)
                    }
                } else {
                    bestExpired = (scopeScore, sortDate, session)
                }
            } else {
                if let currentBest = bestValid {
                    if (scopeScore, sortDate) > (currentBest.score, currentBest.expiry) {
                        bestValid = (scopeScore, sortDate, session)
                    }
                } else {
                    bestValid = (scopeScore, sortDate, session)
                }
            }
        }

        return (bestValid?.session, bestExpired?.session)
    }

    static func parseClaudeCodeOAuth(from data: Data) -> (session: ClaudeSession, hasProfileScope: Bool)? {
        guard let decoded = try? JSONDecoder().decode(ClaudeCodeCredentialsFile.self, from: data),
              let oauth = decoded.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }

        let expiresAt = oauth.expiresAt.map(Self.unixDate(fromEpochNumber:))
        let hasProfileScope: Bool
        if let scopes = oauth.scopes, !scopes.isEmpty {
            hasProfileScope = scopes.contains("user:profile")
        } else {
            hasProfileScope = true
        }
        return (ClaudeSession(accessToken: token, expiresAt: expiresAt), hasProfileScope)
    }

    private static func unixDate(fromEpochNumber raw: Double) -> Date {
        if raw <= 0 {
            return Date(timeIntervalSince1970: 0)
        }
        let seconds = raw > 1_000_000_000_000 ? raw / 1000.0 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Keychain

    /// Reads one generic password service from the login Keychain, checking
    /// existence first so absent services never trigger an unnecessary prompt.
    public static func defaultKeychainLookup(service: String) -> KeychainLookupResult {
        let existsQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let existsStatus = SecItemCopyMatching(existsQuery as CFDictionary, nil)
        if existsStatus == errSecItemNotFound {
            return .notFound
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let password = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !password.isEmpty
            else {
                return .notFound
            }
            return .found(password)
        case errSecItemNotFound:
            return .notFound
        default:
            return .denied(status)
        }
    }

    // MARK: - Chromium crypto

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

    /// Decrypts a Chromium / Electron `"v10"` AES-128-CBC secret payload without
    /// stripping a 32-byte cookie prefix (used for `safeStorage.encryptString`).
    public static func decryptSafeStorageString(_ blob: Data, key: Data) -> String? {
        guard let plaintext = decryptAES128CBC(blob, key: key), !plaintext.isEmpty else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }

    /// Decrypts one Chromium v10 cookie blob (strips the 32-byte domain hash prefix).
    public static func decryptCookie(_ blob: Data, key: Data) -> String? {
        guard let plaintext = decryptAES128CBC(blob, key: key), plaintext.count > 32 else {
            return nil
        }
        let value = plaintext.subdata(in: 32..<plaintext.count)
        return String(data: value, encoding: .utf8)
    }

    private static func decryptAES128CBC(_ blob: Data, key: Data) -> Data? {
        guard key.count == 16 else { return nil }
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }

        let body = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        let outCapacity = body.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        let keyCount = key.count
        let bodyCount = body.count
        var outLength = 0

        let status: CCCryptorStatus = body.withUnsafeBytes { bodyBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    out.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyCount,
                            ivBytes.baseAddress,
                            bodyBytes.baseAddress, bodyCount,
                            outBytes.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outLength > 0 else { return nil }
        return out.prefix(outLength)
    }

    /// `expires_utc` is a count of MICROSECONDS since 1601-01-01T00:00:00Z.
    public static func unixDate(fromChromiumExpires ticks: Int64) -> Date? {
        guard ticks > 0 else { return nil }
        let secondsSince1601 = Double(ticks) / 1_000_000
        let secondsSinceUnixEpoch = secondsSince1601 - 11_644_473_600
        return Date(timeIntervalSince1970: secondsSinceUnixEpoch)
    }

    // MARK: - Read-only SQLite cookie snapshot

    private struct EncryptedCookieRow {
        let name: String
        let blob: Data
        let expiresUTC: Int64
    }

    /// Snapshots a Chromium cookie database plus WAL/SHM sidecars into /tmp and opens
    /// it strictly read-only (`immutable=1`), avoiding lock contention with Chrome.
    private static func readEncryptedCookies(host: String, from dbURL: URL) throws -> [EncryptedCookieRow] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return []
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "claude-cookies-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: dbURL, to: tempURL)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecarSrc = URL(fileURLWithPath: dbURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarSrc.path) {
                let sidecarDst = URL(fileURLWithPath: tempURL.path + suffix)
                try? FileManager.default.copyItem(at: sidecarSrc, to: sidecarDst)
            }
        }
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempURL.path + "-journal"))
        }

        var db: OpaquePointer?
        let uri = "file:" + tempURL.path + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT name, hex(encrypted_value), expires_utc
        FROM cookies
        WHERE host_key LIKE ? AND name IN ('sessionKey','lastActiveOrg','cf_clearance')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, host, -1, SQLITE_TRANSIENT)
        var rows: [EncryptedCookieRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 0),
                  let hexC = sqlite3_column_text(statement, 1)
            else { continue }
            let name = String(cString: nameC)
            let hex = String(cString: hexC)
            let expires = sqlite3_column_int64(statement, 2)
            guard let blob = Data(hexString: hex), !blob.isEmpty else { continue }
            rows.append(EncryptedCookieRow(name: name, blob: blob, expiresUTC: expires))
        }
        return rows
    }

    private struct OAuthCacheEntry: Decodable {
        let token: String?
        let expiresAt: Double?
    }

    private struct ClaudeCodeCredentialsFile: Decodable {
        let claudeAiOauth: OAuthPayload?

        struct OAuthPayload: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let scopes: [String]?
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
