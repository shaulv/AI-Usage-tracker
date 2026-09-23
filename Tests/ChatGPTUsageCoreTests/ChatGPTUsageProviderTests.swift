import XCTest
@testable import ChatGPTUsageCore

/// Plan section 5.4, cases 1 to 3, 5 to 9, 11 to 13.
/// Every test runs against an injected transport and an injected credentials
/// source. No test touches the network or the real home directory.
final class ChatGPTUsageProviderTests: XCTestCase {

    private func provider(
        fixture: String,
        statusCode: Int = 200,
        credentials: CodexCredentials? = nil,
        spy: SpyTransport? = nil
    ) throws -> (ChatGPTUsageProvider, SpyTransport) {
        let data = try Fixture.data(named: fixture)
        let spy = spy ?? SpyTransport(data: data, statusCode: statusCode)
        let credentials = credentials ?? CodexCredentials(
            accessToken: "fake-access-token",
            accountId: "acct-FAKE",
            expiresAt: nil
        )
        let provider = ChatGPTUsageProvider(
            credentialsSource: StubCredentialsSource(credentials: credentials),
            transport: spy.transport,
            now: { TestDates.capture }
        )
        return (provider, spy)
    }

    // MARK: - 1. The captured payload, verbatim

    func test_capturedPayload_mapsTwoLimitsNamedByDuration() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-captured-prolite.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["Weekly", "GPT-5.3-Codex-Spark"])
        XCTAssertEqual(limits[0].usedFraction, 0.06, accuracy: 0.0001)
        XCTAssertEqual(limits[1].usedFraction, 0.0, accuracy: 0.0001)

        // reset_at is epoch SECONDS. Recomputed independently: 1785024392 is
        // 2026-07-26T00:06:32Z and 1785040089 is 2026-07-26T04:28:09Z.
        XCTAssertEqual(TestDates.iso8601(limits[0].resetsAt), "2026-07-26T00:06:32Z")
        XCTAssertEqual(TestDates.iso8601(limits[1].resetsAt), "2026-07-26T04:28:09Z")

        // The menu bar shows a rounded integer percent.
        XCTAssertEqual(limits[0].usedPercentRounded, 6)
    }

    // MARK: - 2. Plus-shaped payload: names must not depend on position

    func test_plusShapedPayload_namesSessionAndWeeklyByDurationNotPosition() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-plus-two-windows.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["Session (5h)", "Weekly"])
        XCTAssertEqual(limits[0].usedFraction, 0.45, accuracy: 0.0001)
        XCTAssertEqual(limits[1].usedFraction, 0.72, accuracy: 0.0001)
    }

    // MARK: - 3. 259200 seconds is a 30-day window

    func test_thirtyDayWindow_isNamedThirtyDay() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-thirty-day-window.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["30-day"])
    }

    // MARK: - 4. Absent duration falls back to positional naming, no crash

    func test_missingWindowDuration_fallsBackToPositionalName() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-no-window-duration.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["Primary limit", "Secondary limit"])
        XCTAssertEqual(limits[0].usedFraction, 0.33, accuracy: 0.0001)
        XCTAssertEqual(limits[1].usedFraction, 0.44, accuracy: 0.0001)
    }

    // MARK: - 5. Out-of-range percentages clamp instead of propagating

    func test_outOfRangePercent_clampsToZeroAndOne() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-out-of-range-percent.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits[0].usedFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(limits[0].usedPercentRounded, 100)
        XCTAssertEqual(limits[1].usedFraction, 0.0, accuracy: 0.0001)
    }

    // MARK: - 6. Nothing the server sends is silently dropped

    func test_unnamedAdditionalLimit_fallsBackToMeteredFeature() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-unnamed-additional.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["Codex foo bar", "Additional limit"])
    }

    // MARK: - 7. An unrecognized payload is a failure, not an empty list

    func test_unrecognizedPayload_throwsFetchFailedNotEmptyList() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-unrecognized.json")

        do {
            let limits = try await provider.fetchLimits()
            XCTFail("expected a fetch failure, got \(limits)")
        } catch {
            let providerError = assertProviderError(error)
            guard case .fetchFailed(let message)? = providerError else {
                return XCTFail("expected fetchFailed, got \(String(describing: providerError))")
            }
            XCTAssertEqual(message, "Unexpected response from ChatGPT usage service")
        }
    }

    // MARK: - 8. A recognized payload with zero windows is a real answer

    func test_recognizedPayloadWithNoWindows_returnsEmptyArray() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-no-windows.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits, [])
    }

    // MARK: - 9. The expiry gate short-circuits BEFORE the network

    func test_expiredJWT_failsLocallyAndNeverCallsTheNetwork() async throws {
        // exp 1600000000 is 2020-09-13T12:26:40Z, far past the test clock of
        // 2026-07-19. The gate must catch this without a request.
        let credentials = CodexCredentials(
            accessToken: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2MDAwMDAwMDB9.FAKESIG",
            accountId: "acct-FAKE",
            expiresAt: Date(timeIntervalSince1970: 1600000000)
        )
        let spy = SpyTransport(data: try Fixture.data(named: "wham-usage-captured-prolite.json"))
        let (provider, _) = try provider(
            fixture: "wham-usage-captured-prolite.json",
            credentials: credentials,
            spy: spy
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected the expiry gate to reject this token")
        } catch {
            let providerError = assertProviderError(error)
            guard case .notConnected(let message)? = providerError else {
                return XCTFail("expected notConnected, got \(String(describing: providerError))")
            }
            XCTAssertEqual(message, "Codex session expired - run codex to refresh it")
        }

        // This is the assertion that fails if the gate is ever unwired.
        XCTAssertEqual(spy.callCount, 0, "the expiry gate must not make a network call")
    }

    // MARK: - 11. 401 is a credential problem and its body is never parsed

    func test_http401_isNotConnected() async throws {
        let (provider, _) = try provider(
            fixture: "wham-usage-captured-prolite.json",
            statusCode: 401
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            let providerError = assertProviderError(error)
            guard case .notConnected(let message)? = providerError else {
                return XCTFail("expected notConnected, got \(String(describing: providerError))")
            }
            XCTAssertEqual(message, "ChatGPT rejected the saved credentials - sign in to Codex again")
        }
    }

    // MARK: - 12. Any other non-2xx reports its status code

    func test_http503_isFetchFailedWithStatusCode() async throws {
        let (provider, _) = try provider(
            fixture: "wham-usage-captured-prolite.json",
            statusCode: 503
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a fetchFailed error")
        } catch {
            let providerError = assertProviderError(error)
            guard case .fetchFailed(let message)? = providerError else {
                return XCTFail("expected fetchFailed, got \(String(describing: providerError))")
            }
            XCTAssertTrue(message.contains("503"), "message was: \(message)")
        }
    }

    // MARK: - 13. An HTML interstitial served as 200 must not read as data

    func test_htmlBodyWith200_isFetchFailed() async throws {
        let (provider, _) = try provider(fixture: "wham-usage-html-interstitial.html", statusCode: 200)

        do {
            let limits = try await provider.fetchLimits()
            XCTFail("expected a fetch failure, got \(limits)")
        } catch {
            let providerError = assertProviderError(error)
            guard case .fetchFailed(let message)? = providerError else {
                return XCTFail("expected fetchFailed, got \(String(describing: providerError))")
            }
            XCTAssertEqual(message, "Unexpected response from ChatGPT usage service")
        }
    }

    // MARK: - Transport failure

    func test_networkFailure_isFetchFailed() async throws {
        let provider = ChatGPTUsageProvider(
            credentialsSource: StubCredentialsSource(
                credentials: CodexCredentials(accessToken: "fake", accountId: nil, expiresAt: nil)
            ),
            transport: FailingTransport.transport,
            now: { TestDates.capture }
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a fetch failure")
        } catch {
            let providerError = assertProviderError(error)
            guard case .fetchFailed(let message)? = providerError else {
                return XCTFail("expected fetchFailed, got \(String(describing: providerError))")
            }
            XCTAssertEqual(message, "Network error - check your connection")
        }
    }

    // MARK: - The request itself

    func test_request_carriesBearerAccountAndOriginatorHeaders() throws {
        let credentials = CodexCredentials(
            accessToken: "fake-access-token",
            accountId: "acct-FAKE",
            expiresAt: nil
        )

        let request = ChatGPTUsageProvider.makeRequest(credentials: credentials)

        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-FAKE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func test_request_omitsAccountHeaderWhenAccountIdIsAbsent() throws {
        let credentials = CodexCredentials(accessToken: "fake", accountId: nil, expiresAt: nil)

        let request = ChatGPTUsageProvider.makeRequest(credentials: credentials)

        XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    func test_provider_idIsStable() {
        let provider = ChatGPTUsageProvider(
            credentialsSource: StubCredentialsSource(
                credentials: CodexCredentials(accessToken: "fake", accountId: nil, expiresAt: nil)
            ),
            transport: FailingTransport.transport
        )
        XCTAssertEqual(provider.id, "chatgpt")
        XCTAssertEqual(provider.displayName, "ChatGPT")
    }
}
