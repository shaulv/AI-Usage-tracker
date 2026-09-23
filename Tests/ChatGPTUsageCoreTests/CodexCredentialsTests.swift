import XCTest
@testable import ChatGPTUsageCore

/// Plan section 5.4, cases 10 and 14, plus the JWT expiry decode rules and the
/// file-reader paths that `load()` adds on top of `parseCredentials`.
final class CodexCredentialsTests: XCTestCase {

    // MARK: - Parsing a real-shaped auth.json

    func test_validAuthFile_yieldsTokenAccountAndExpiry() throws {
        let data = try Fixture.data(named: "auth-chatgpt-valid.json")

        let credentials = try CodexAuthFileCredentialsSource.parseCredentials(data)

        XCTAssertTrue(credentials.accessToken.hasPrefix("eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9."))
        XCTAssertEqual(credentials.accountId, "acct-FAKE")
        // exp 4102444800 is 2100-01-01T00:00:00Z.
        XCTAssertEqual(TestDates.iso8601(credentials.expiresAt), "2100-01-01T00:00:00Z")
        XCTAssertFalse(credentials.isExpired(now: TestDates.capture))
    }

    // MARK: - 14. API-key sign-in gets its own message

    func test_apiKeyAuthFile_reportsTheApiKeyMessage() throws {
        let data = try Fixture.data(named: "auth-apikey.json")

        XCTAssertThrowsError(try CodexAuthFileCredentialsSource.parseCredentials(data)) { error in
            guard case UsageProviderError.notConnected(let message) = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
            XCTAssertEqual(
                message,
                "Codex is signed in with an API key - sign in with ChatGPT to see plan limits"
            )
        }
    }

    func test_authModeApiKeyWithoutKeyAlso_reportsTheApiKeyMessage() throws {
        let json = """
        { "auth_mode": "apiKey", "OPENAI_API_KEY": null, "tokens": null }
        """

        XCTAssertThrowsError(
            try CodexAuthFileCredentialsSource.parseCredentials(Data(json.utf8))
        ) { error in
            guard case UsageProviderError.notConnected(let message) = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
            XCTAssertTrue(message.contains("API key"), "message was: \(message)")
        }
    }

    func test_missingTokensWithChatGptAuthMode_reportsNotSignedIn() throws {
        let json = """
        { "auth_mode": "chatgpt", "OPENAI_API_KEY": null, "tokens": null }
        """

        XCTAssertThrowsError(
            try CodexAuthFileCredentialsSource.parseCredentials(Data(json.utf8))
        ) { error in
            guard case UsageProviderError.notConnected(let message) = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
            XCTAssertEqual(message, "Not signed in to Codex")
        }
    }

    func test_malformedJSON_reportsMalformedCredentials() throws {
        XCTAssertThrowsError(
            try CodexAuthFileCredentialsSource.parseCredentials(Data("{ not json".utf8))
        ) { error in
            guard case UsageProviderError.notConnected(let message) = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
            XCTAssertTrue(message.contains("malformed"), "message was: \(message)")
        }
    }

    func test_missingFile_reportsNotSignedIn() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "codex-auth-does-not-exist-\(UUID().uuidString).json")
        let source = CodexAuthFileCredentialsSource(authFileURL: missing)

        XCTAssertThrowsError(try source.load()) { error in
            guard case UsageProviderError.notConnected(let message) = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
            XCTAssertEqual(message, "Not signed in to Codex")
        }
    }

    func test_loadFromDisk_matchesParseCredentials() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "codex-auth-\(UUID().uuidString).json")
        try Fixture.data(named: "auth-chatgpt-valid.json").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let credentials = try CodexAuthFileCredentialsSource(authFileURL: url).load()

        XCTAssertEqual(credentials.accountId, "acct-FAKE")
    }

    // MARK: - JWT expiry decoding

    func test_expiredJWTHasAnExpiryInThePast() throws {
        let data = try Fixture.data(named: "auth-chatgpt-expired.json")

        let credentials = try CodexAuthFileCredentialsSource.parseCredentials(data)

        XCTAssertEqual(TestDates.iso8601(credentials.expiresAt), "2020-09-13T12:26:40Z")
        XCTAssertTrue(credentials.isExpired(now: TestDates.capture))
    }

    // MARK: - 10. An undecodable JWT must not lock the user out

    func test_undecodableJWT_yieldsNoExpiryAndIsNotTreatedAsExpired() throws {
        let json = """
        {
          "auth_mode": "chatgpt",
          "tokens": { "access_token": "not-a-jwt-at-all", "account_id": "acct-FAKE" }
        }
        """

        let credentials = try CodexAuthFileCredentialsSource.parseCredentials(Data(json.utf8))

        XCTAssertNil(credentials.expiresAt)
        XCTAssertFalse(credentials.isExpired(now: TestDates.capture))
    }

    func test_jwtWithoutExpiryClaim_yieldsNoExpiry() {
        // Header is valid base64url, payload is `{"sub":"x"}` with no exp.
        let token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.sig"

        XCTAssertNil(CodexAuthFileCredentialsSource.expiry(fromJWT: token))
    }

    func test_jwtWithUnpaddedBase64URLPayload_stillDecodes() {
        // `{"exp":1600000000}` base64url-encoded without padding.
        let token = "header.eyJleHAiOjE2MDAwMDAwMDB9.sig"

        let expiry = CodexAuthFileCredentialsSource.expiry(fromJWT: token)

        XCTAssertEqual(TestDates.iso8601(expiry), "2020-09-13T12:26:40Z")
    }

    func test_expiryGraceWindow_doesNotRejectATokenInsideSixtySeconds() {
        let now = TestDates.capture
        let justExpired = CodexCredentials(
            accessToken: "fake",
            accountId: nil,
            expiresAt: now.addingTimeInterval(-30)
        )
        let clearlyExpired = CodexCredentials(
            accessToken: "fake",
            accountId: nil,
            expiresAt: now.addingTimeInterval(-120)
        )

        XCTAssertFalse(justExpired.isExpired(now: now))
        XCTAssertTrue(clearlyExpired.isExpired(now: now))
    }

    // MARK: - Window naming, the unit behind cases 2, 3 and 4

    func test_windowNamer_coversEveryDurationBranch() {
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 18000, fallback: "x"), "Session (5h)")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 10800, fallback: "x"), "Session (3h)")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 9000, fallback: "x"), "Session (2.5h)")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 604800, fallback: "x"), "Weekly")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 2592000, fallback: "x"), "30-day")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 2678400, fallback: "x"), "31-day")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 259200, fallback: "x"), "3-day")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: nil, fallback: "Primary limit"), "Primary limit")
        XCTAssertEqual(WindowNamer.name(forWindowSeconds: 0, fallback: "Primary limit"), "Primary limit")
    }

    func test_humanizer_turnsMeteredFeatureIntoAReadableName() {
        XCTAssertEqual(WindowNamer.humanize("codex_foo_bar"), "Codex foo bar")
        XCTAssertEqual(WindowNamer.humanize("  codex_bengalfox "), "Codex bengalfox")
        XCTAssertEqual(WindowNamer.humanize(""), "")
        XCTAssertEqual(WindowNamer.humanize("   "), "")
    }
}
