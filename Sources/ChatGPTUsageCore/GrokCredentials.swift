import Foundation
import Security
import CommonCrypto

/// The Grok Bot desktop session this app borrows, read-only.
///
/// Grok Bot is a Cursor fork, so its session looks like Cursor's turned
/// inside out. Cursor IDE stores a plain JWT in state.vscdb; Grok Bot stores
/// a Chromium-style encrypted blob in `sand-secrets.json` and the decrypt key
/// in the login Keychain under `Grok Bot Safe Storage`. Verified end to end
/// against the live install on 29/09/2026 before any Swift was written:
/// the token is base64 of `"v10" || AES-128-CBC(plaintext JWT)`, the AES key
/// is `PBKDF2-HMAC-SHA1(keychain password UTF-8 bytes, salt "saltysalt",
/// 1003 rounds, 16 bytes)`, IV is 16 spaces, PKCS7. The password is the
/// Keychain string AS TEXT: base64-decoding it first produces a valid-looking
/// key that decrypts to garbage (measured). The plaintext IS the JWT
/// directly (HS256, iss `https://authentication.cursor.sh`): unlike the
/// Claude cookie path, there is no 32-byte prefix to strip.
///
/// Two rules, same as every other credential source here:
/// 1. Never refresh anything and never write. Grok Bot owns its session and
///    refreshes it during normal use; this app reads whatever is current.
/// 2. Never log a token, and never write to the secrets file. Read-only,
///    provably: the file is opened with `Data(contentsOf:)` and the Keychain
///    query asks for one generic password only.
public struct GrokCredentials: Equatable, Sendable {
    let accessToken: String
    let machineId: String
    let email: String?
    /// From the JWT `exp` claim, epoch seconds. Nil when the token does not
    /// decode, which is treated as "expiry unknown", never as "expired".
    let expiresAt: Date?

    /// True when the token is provably past its expiry, with a 60 second grace
    /// window so clock skew between this Mac and Cursor does not lock the user
    /// out of their own usage view.
    func isExpired(now: Date, grace: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(grace) < now
    }
}

/// The seam that makes every Grok credential error testable without a real
/// secrets file or Keychain item on the machine running the tests.
public protocol GrokCredentialsSource: Sendable {
    func load() throws -> GrokCredentials
}

/// Reads Grok Bot's own session: the encrypted token from `sand-secrets.json`,
/// decrypted with the Keychain's `Grok Bot Safe Storage` password.
public struct GrokBotCredentialsSource: GrokCredentialsSource {
    let secretsFileURL: URL

    public init(secretsFileURL: URL? = nil) {
        if let secretsFileURL {
            self.secretsFileURL = secretsFileURL
            return
        }
        self.secretsFileURL = Self.defaultSecretsFileURL()
    }

    public func load() throws -> GrokCredentials {
        let data: Data
        do {
            data = try Data(contentsOf: secretsFileURL)
        } catch {
            throw UsageProviderError.notConnected(
                "Grok Bot is not signed in - open Grok Bot and sign in"
            )
        }
        let password: String
        do {
            password = try Self.keychainPassword()
        } catch {
            throw UsageProviderError.notConnected(
                "Grok Bot is not signed in - open Grok Bot and sign in"
            )
        }
        return try Self.parseCredentials(data, keychainPassword: password)
    }

    /// Split out from `load()` so the parsing and decrypt rules are
    /// unit-testable from raw bytes, with no filesystem or Keychain involved.
    public static func parseCredentials(
        _ data: Data,
        keychainPassword password: String
    ) throws -> GrokCredentials {
        let decoded: SecretsFile
        do {
            decoded = try JSONDecoder().decode(SecretsFile.self, from: data)
        } catch {
            throw UsageProviderError.notConnected(
                "Grok Bot credentials are malformed - open Grok Bot again"
            )
        }
        let machineId = (decoded.machineId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountsJSON = (decoded.accounts ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !machineId.isEmpty, !accountsJSON.isEmpty,
              let accountsData = accountsJSON.data(using: .utf8),
              let accounts = try? JSONDecoder().decode(
                CursorAccounts.self, from: accountsData
              ),
              let slot = accounts.accounts[accounts.active],
              !slot.accessToken.isEmpty,
              let blob = Data(base64Encoded: slot.accessToken)
        else {
            throw UsageProviderError.notConnected(
                "Grok Bot is not signed in - open Grok Bot and sign in"
            )
        }
        let key = ClaudeDesktopSessionSource.deriveKey(password: password)
        guard let accessToken = Self.decryptToken(blob, key: key),
              !accessToken.isEmpty
        else {
            throw UsageProviderError.notConnected(
                "Grok Bot rejected the saved session - reopen Grok Bot to refresh it"
            )
        }
        return GrokCredentials(
            accessToken: accessToken,
            machineId: machineId,
            email: nil,
            expiresAt: Self.expiry(fromJWT: accessToken)
        )
    }

    /// Decrypts one Chromium v10 token blob. Returns nil for any shape this
    /// code does not recognize rather than guessing: a wrong guess here would
    /// send a garbage token to api2.cursor.sh. Same recipe as the Claude
    /// cookie decrypt except for the last step: the plaintext here is the JWT
    /// itself, with no 32-byte prefix to strip.
    public static func decryptToken(_ blob: Data, key: Data) -> String? {
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
        guard status == kCCSuccess, outLength > 0 else { return nil }
        return String(data: out.prefix(outLength), encoding: .utf8)
    }

    /// Reads the `Grok Bot Safe Storage` secret from the login Keychain. The
    /// first access from this app may show a one-time macOS approval dialog;
    /// that is the system doing its job, and the user's answer applies after.
    public static func keychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Grok Bot Safe Storage",
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
            throw UsageProviderError.notConnected(
                "Grok Bot is not signed in - open Grok Bot and sign in"
            )
        }
        return password
    }

    /// Best-effort decode of the JWT `exp` claim. Every failure path returns
    /// nil and the caller proceeds to the network, where the server's 401 is
    /// the real authority. A base64 quirk here must never lock a user out.
    public static func expiry(fromJWT token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let payload = Data(base64Encoded: base64) else { return nil }
        guard let claims = try? JSONDecoder().decode(JWTExpiry.self, from: payload) else { return nil }
        guard let exp = claims.exp, exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func defaultSecretsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Application Support")
            .appending(path: "Grok Bot")
            .appending(path: "sand-secrets.json")
    }

    private struct SecretsFile: Decodable {
        let machineId: String?
        let accounts: String?
        enum CodingKeys: String, CodingKey {
            case machineId = "cursor-machine-id"
            case accounts = "cursor-accounts"
        }
    }

    private struct CursorAccounts: Decodable {
        let active: String
        let accounts: [String: AccountSlot]
        struct AccountSlot: Decodable {
            let accessToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "cursor-access-token"
            }
        }
    }

    private struct JWTExpiry: Decodable {
        let exp: Double?
    }
}
