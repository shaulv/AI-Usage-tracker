import Foundation

/// The only credential this app ever touches, and it only ever READS it.
///
/// Two rules that are load-bearing:
///
/// 1. Never refresh the token. The refresh token rotates, and consuming it
///    out-of-band can invalidate the session Codex CLI holds and log the user
///    out of `codex`. Codex refreshes `auth.json` during normal use; this app
///    just reads whatever is current.
/// 2. Never log a token, and never write to the file. Read-only, provably.
public struct CodexCredentials: Equatable {
    let accessToken: String
    let accountId: String?
    /// From the JWT `exp` claim, epoch seconds. Nil when the token does not
    /// decode, which is treated as "expiry unknown", never as "expired".
    let expiresAt: Date?

    /// True when the token is provably past its expiry, with a 60 second grace
    /// window so clock skew between this Mac and OpenAI does not lock the user
    /// out of their own dashboard.
    func isExpired(now: Date, grace: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(grace) < now
    }
}

/// The seam that makes every credential error testable without a real file on
/// disk. Two implementations exist (the file reader and test stubs), so this is
/// a real seam rather than a speculative one.
public protocol CodexCredentialsSource {
    func load() throws -> CodexCredentials
}

/// Reads `~/.codex/auth.json`, or `$CODEX_HOME/auth.json` when Codex has been
/// pointed at a second directory to run a second account.
public struct CodexAuthFileCredentialsSource: CodexCredentialsSource {
    let authFileURL: URL

    public init(authFileURL: URL? = nil) {
        if let authFileURL {
            self.authFileURL = authFileURL
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let root: URL
        if let codexHome {
            root = (codexHome as NSString).expandingTildeInPath.isEmpty
                ? home.appending(path: ".codex")
                : URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
        } else {
            root = home.appending(path: ".codex")
        }
        self.authFileURL = root.appending(path: "auth.json")
    }

    public func load() throws -> CodexCredentials {
        let data: Data
        do {
            data = try Data(contentsOf: authFileURL)
        } catch {
            // A missing file and an unreadable file get the same message on
            // purpose: both mean "no usable Codex sign-in here".
            throw UsageProviderError.notConnected("Not signed in to Codex")
        }
        return try Self.parseCredentials(data)
    }

    /// Split out from `load()` so the parsing rules are unit-testable from raw
    /// bytes, with no filesystem involved.
    public static func parseCredentials(_ data: Data) throws -> CodexCredentials {
        let decoded: AuthFile
        do {
            decoded = try JSONDecoder().decode(AuthFile.self, from: data)
        } catch {
            throw UsageProviderError.notConnected(
                "Codex credentials are malformed - sign in to Codex again"
            )
        }

        let accessToken = (decoded.tokens?.accessToken ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if accessToken.isEmpty {
            // An API-key sign-in has no ChatGPT plan windows to report. Say
            // that specifically, because the fix is a different sign-in.
            if decoded.openAIAPIKey != nil, !(decoded.openAIAPIKey ?? "").isEmpty {
                throw UsageProviderError.notConnected(
                    "Codex is signed in with an API key - sign in with ChatGPT to see plan limits"
                )
            }
            if (decoded.authMode ?? "").lowercased() == "apikey" {
                throw UsageProviderError.notConnected(
                    "Codex is signed in with an API key - sign in with ChatGPT to see plan limits"
                )
            }
            throw UsageProviderError.notConnected("Not signed in to Codex")
        }

        return CodexCredentials(
            accessToken: accessToken,
            accountId: decoded.tokens?.accountId,
            expiresAt: expiry(fromJWT: accessToken)
        )
    }

    /// Best-effort decode of the JWT `exp` claim.
    ///
    /// Every failure path returns nil and the caller proceeds to the network,
    /// where the server's 401 is the real authority. A base64 quirk in this
    /// function must never lock a user out of their own usage dashboard.
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

    private struct AuthFile: Decodable {
        let authMode: String?
        let openAIAPIKey: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case openAIAPIKey = "OPENAI_API_KEY"
            case tokens
        }

        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }

    private struct JWTExpiry: Decodable {
        let exp: Double?
    }
}
