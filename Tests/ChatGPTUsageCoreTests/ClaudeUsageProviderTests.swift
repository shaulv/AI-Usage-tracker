import Foundation
import XCTest
@testable import ChatGPTUsageCore

/// Claude contract tests, built from the shapes the live probe actually
/// returned: HTTP 200 with the bucket keys present and `null` values (free plan,
/// nothing metered yet) is a recognized empty answer, never an error.
final class ClaudeUsageProviderTests: XCTestCase {

    // MARK: - Mapping (fixtures)

    func test_mappedPayload_namesSessionWeeklyAndModelRowsByDuration() throws {
        let data = try Fixture.data(named: "claude-usage-mapped.json")
        let limits = try ClaudeUsageMapper.limits(from: data)

        XCTAssertEqual(limits.map(\.name), ["Session (5h)", "Weekly", "Weekly (Opus)", "Extra usage"])
        // 12.5 rounds to 13 (Swift's .rounded() is round-half-away-from-zero).
        XCTAssertEqual(limits.map(\.usedPercentRounded), [6, 35, 12, 13])
        let weekly = try XCTUnwrap(limits.first { $0.name == "Weekly" })
        XCTAssertEqual(weekly.resetsAt, ClaudeUsageResponse.parseReset("2026-04-14T16:59:59Z"))
        // Extra usage is a credits balance, not a window: no reset claim.
        XCTAssertNil(limits.first { $0.name == "Extra usage" }?.resetsAt)
    }

    func test_nullBuckets_recognizedAsEmptyListNotAnError() throws {
        // The literal shape the live probe returned for this account.
        let data = try Fixture.data(named: "claude-usage-null-buckets.json")
        let limits = try ClaudeUsageMapper.limits(from: data)
        XCTAssertEqual(limits, [])
    }

    func test_unrecognizedPayload_throwsFetchFailed() {
        let data = Data(#"{"unexpected":"shape"}"#.utf8)
        XCTAssertThrowsError(try ClaudeUsageMapper.limits(from: data)) { error in
            XCTAssertEqual(assertProviderError(error)?.message, "Unexpected response from Claude usage service")
        }
    }

    func test_htmlBodyWith200_isFetchFailed() throws {
        let data = try Fixture.data(named: "wham-usage-html-interstitial.html")
        XCTAssertThrowsError(try ClaudeUsageMapper.limits(from: data)) { error in
            XCTAssertEqual(assertProviderError(error)?.message, "Unexpected response from Claude usage service")
        }
    }

    func test_outOfRangePercent_clampsToZeroAndOne() throws {
        let data = try Fixture.data(named: "claude-usage-out-of-range.json")
        let limits = try ClaudeUsageMapper.limits(from: data)
        XCTAssertEqual(limits.first { $0.name == "Weekly" }?.usedFraction, 1.0)
        XCTAssertEqual(limits.first { $0.name == "Session (5h)" }?.usedFraction, 0.0)
    }

    func test_parseReset_handlesMicrosecondsAndOffsets() {
        let date = ClaudeUsageResponse.parseReset("2026-04-11T07:00:00.528743+00:00")
        XCTAssertNotNil(date, "Microsecond timestamps must parse successfully")
    }

    func test_parseReset_handlesMillisecondsAndUTCZ() {
        let date = ClaudeUsageResponse.parseReset("2026-04-11T07:00:00.528Z")
        XCTAssertNotNil(date, "Millisecond timestamps must parse successfully")
    }

    func test_parseReset_preservesStandardRFC3339() {
        let date = ClaudeUsageResponse.parseReset("2026-04-08T18:59:59Z")
        XCTAssertNotNil(date, "Standard RFC 3339 without fractions must continue to parse")
    }

    func test_parseReset_handlesNumericEpochSeconds() {
        let date = ClaudeUsageResponse.parseReset("1775890800")
        XCTAssertNotNil(date, "Epoch seconds string must parse into Date")
    }

    func test_mappedPayload_withFractionalTimestamps_populatesResetsAt() throws {
        let json = """
        {
          "five_hour": { "utilization": 99.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
          "seven_day": { "utilization": 100.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" }
        }
        """
        let limits = try ClaudeUsageMapper.limits(from: Data(json.utf8))
        XCTAssertEqual(limits.count, 2)
        XCTAssertNotNil(limits.first?.resetsAt, "Session limit must have a valid non-nil reset date")
        XCTAssertNotNil(limits.last?.resetsAt, "Weekly limit must have a valid non-nil reset date")
    }

    func test_bucketDecodes_fromNumericResetsAt() throws {
        let json = """
        {
          "five_hour": { "utilization": 50.0, "resets_at": 1775890800 }
        }
        """
        let limits = try ClaudeUsageMapper.limits(from: Data(json.utf8))
        XCTAssertEqual(limits.count, 1)
        XCTAssertNotNil(limits.first?.resetsAt, "Numeric resets_at should decode and parse into Date")
    }

    // MARK: - Provider behavior (injected transport + session stub)

    private func makeProvider(
        session: Result<ClaudeSession, Error>,
        transport: @escaping ChatGPTUsageProvider.Transport
    ) -> ClaudeUsageProvider {
        ClaudeUsageProvider(
            sessionSource: StubClaudeSessionSource(result: session),
            transport: transport,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    private func liveSession() -> ClaudeSession {
        ClaudeSession(
            sessionKey: "sk-ant-sid01-FORCED",
            organizationId: "org-00000000-0000-0000-0000-000000000000",
            cfClearance: "cf-clearance-FORCED",
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    func test_request_carriesCookiesChromeUAAndAccept() throws {
        let request = ClaudeUsageProvider.makeRequest(session: liveSession())

        XCTAssertEqual(request.url?.host, "claude.ai")
        XCTAssertEqual(request.url?.path, "/api/organizations/org-00000000-0000-0000-0000-000000000000/usage")
        let cookie = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("sessionKey=sk-ant-sid01-FORCED"))
        XCTAssertTrue(cookie.contains("lastActiveOrg=org-00000000-0000-0000-0000-000000000000"))
        XCTAssertTrue(cookie.contains("cf_clearance=cf-clearance-FORCED"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        // This endpoint authenticates with cookies only.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_request_omitsCfClearanceWhenAbsent() throws {
        let session = ClaudeSession(
            sessionKey: "sk-ant-sid01-FORCED",
            organizationId: "org",
            cfClearance: nil,
            expiresAt: nil
        )
        let cookie = ClaudeUsageProvider.makeRequest(session: session)
            .value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(cookie.contains("cf_clearance"))
    }

    func test_expiredSession_failsLocallyAndNeverCallsTheNetwork() async {
        let spy = SpyTransport()
        let expired = ClaudeSession(
            sessionKey: "sk-ant-sid01-FORCED",
            organizationId: "org",
            cfClearance: nil,
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let provider = makeProvider(session: .success(expired), transport: spy.transport)

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            XCTAssertEqual(assertProviderError(error)?.message, "Claude session expired - open Claude to refresh it")
        }
        XCTAssertEqual(spy.callCount, 0, "an expired session must not reach the network")
    }

    func test_missingCookieStore_reportsClaudeDesktopNotSignedIn() async {
        let provider = makeProvider(
            session: .failure(UsageProviderError.notConnected("Claude Desktop is not signed in on this Mac")),
            transport: SpyTransport().transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            XCTAssertEqual(assertProviderError(error)?.message, "Claude Desktop is not signed in on this Mac")
        }
    }

    func test_http403WithCloudflareChallenge_reportsBlockedNotExpired() async throws {
        // The live answer since 23/09/2026: HTTP 403 whose body is Cloudflare's
        // managed challenge. The fix is not "refresh your session", so the
        // message must not say that.
        let data = try Fixture.data(named: "claude-cf-challenge.html")
        let provider = makeProvider(
            session: .success(liveSession()),
            transport: SpyTransport(data: data, statusCode: 403).transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            XCTAssertEqual(
                assertProviderError(error)?.message,
                "Claude is blocked by Cloudflare - open Claude Desktop, then Refresh"
            )
        }
    }

    func test_http403WithoutChallengeMarker_stillReportsExpiredSession() async {
        // The pre-existing behavior must survive: a 403 that is not a challenge
        // is still an aged-out session.
        let provider = makeProvider(
            session: .success(liveSession()),
            transport: SpyTransport(data: Data("{\"error\":\"unauthorized\"}".utf8), statusCode: 403).transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            XCTAssertEqual(assertProviderError(error)?.message, "Claude session expired - open Claude to refresh it")
        }
    }

    func test_cloudflareChallengeRecognizer_readsBothTheHeaderAndTheBody() {
        // Asserted directly because `SpyTransport` always reports a JSON
        // Content-Type, so it cannot exercise the header branch.
        let url = URL(string: "https://claude.ai/api/organizations/org/usage")!
        let plain = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertFalse(ClaudeUsageProvider.isCloudflareChallenge(body: Data("{}".utf8), response: plain))

        let mitigated = HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["cf-mitigated": "challenge"]
        )!
        XCTAssertTrue(ClaudeUsageProvider.isCloudflareChallenge(body: Data("{}".utf8), response: mitigated))

        XCTAssertTrue(
            ClaudeUsageProvider.isCloudflareChallenge(
                body: Data("<title>Just a moment...</title>".utf8),
                response: plain
            )
        )
        XCTAssertTrue(
            ClaudeUsageProvider.isCloudflareChallenge(
                body: Data("<script>window._cf_chl_opt = {};</script>".utf8),
                response: plain
            )
        )
    }

    func test_http500_isFetchFailedWithStatusCodeInMessage() async {
        let provider = makeProvider(
            session: .success(liveSession()),
            transport: SpyTransport(data: Data("{}".utf8), statusCode: 500).transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a fetchFailed error")
        } catch {
            XCTAssertEqual(assertProviderError(error)?.message, "Claude usage service returned HTTP 500")
        }
    }

    func test_networkFailure_isFetchFailed() async {
        let provider = makeProvider(session: .success(liveSession()), transport: FailingTransport.transport)
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a fetchFailed error")
        } catch {
            XCTAssertEqual(assertProviderError(error)?.message, "Network error - check your connection")
        }
    }

    func test_200WithNullBuckets_returnsEmptyArray() async throws {
        let data = try Fixture.data(named: "claude-usage-null-buckets.json")
        let provider = makeProvider(
            session: .success(liveSession()),
            transport: SpyTransport(data: data, statusCode: 200).transport
        )
        let limits = try await provider.fetchLimits()
        XCTAssertEqual(limits, [])
    }

    func test_provider_idIsStable() {
        XCTAssertEqual(ClaudeUsageProvider().id, "claude")
        XCTAssertEqual(ClaudeUsageProvider().displayName, "Claude")
    }

    // MARK: - Cookie decryption (the recipe the live probe proved)

    func test_keyDerivation_matchesTheProvenRecipe() {
        // Deterministic PBKDF2-HMAC-SHA1("password", "saltysalt", 1003, 16);
        // the expected hex is from the Python probe that first decoded the real
        // cookie store, so Swift must agree with the proven recipe bit for bit.
        let key = ClaudeDesktopSessionSource.deriveKey(password: "password")
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "9395139d5abdba8b749042ad882c0937"
        )
    }

    func test_decryptCookie_rejectsUnknownShapes() {
        // Not v10, truncated, and wrong key size must all refuse rather than
        // send garbage to claude.ai.
        XCTAssertNil(ClaudeDesktopSessionSource.decryptCookie(Data("v99junk".utf8), key: Data(count: 16)))
        XCTAssertNil(ClaudeDesktopSessionSource.decryptCookie(Data("v10".utf8), key: Data(count: 16)))
        XCTAssertNil(ClaudeDesktopSessionSource.decryptCookie(Data("v10junk".utf8), key: Data()))
    }

    func test_expiries_convertChromiumTicksToUnixDates() throws {
        // 13437063650655199 ticks is the live sessionKey expiry seen on the
        // real install; it must land in 2026, not 1970 and not 2500.
        let date = try XCTUnwrap(ClaudeDesktopSessionSource.unixDate(fromChromiumExpires: 13_437_063_650_655_199))
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        XCTAssertEqual(year, 2026)
        XCTAssertNil(ClaudeDesktopSessionSource.unixDate(fromChromiumExpires: 0))
    }
}

/// The Claude-side stub, mirroring `StubCredentialsSource`.
private struct StubClaudeSessionSource: ClaudeSessionSource, @unchecked Sendable {
    let result: Result<ClaudeSession, Error>

    func load() throws -> ClaudeSession {
        try result.get()
    }
}
