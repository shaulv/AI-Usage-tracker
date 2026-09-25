import XCTest
@testable import ChatGPTUsageCore

/// Cursor provider: monthly Auto + API pools mapped from fixed percent fields
/// (no duration naming), both rows always rendered, shared billing-cycle reset.
/// Every test runs against an injected transport and stub credentials. No test
/// touches the network or the real home directory.
final class CursorUsageProviderTests: XCTestCase {

    private func provider(
        fixture: String,
        statusCode: Int = 200,
        credentials: CursorCredentials? = nil
    ) throws -> (CursorUsageProvider, SpyTransport) {
        let data = try Fixture.data(named: fixture)
        let spy = SpyTransport(data: data, statusCode: statusCode)
        let credentials = credentials ?? CursorCredentials(
            accessToken: "fake-cursor-token",
            email: "dev@example.com",
            planTier: "pro",
            expiresAt: nil
        )
        let provider = CursorUsageProvider(
            credentialsSource: StubCursorCredentialsSource(credentials: credentials),
            transport: spy.transport,
            now: { TestDates.capture }
        )
        return (provider, spy)
    }

    // MARK: - 1. Basic payload maps two monthly rows with shared reset

    func test_basicPayload_mapsAutoAndApiRows() async throws {
        let (provider, _) = try provider(fixture: "cursor-current-period-basic.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["Cursor Auto", "Cursor API"])
        XCTAssertEqual(limits[0].usedFraction, 0.30, accuracy: 0.0001)
        XCTAssertEqual(limits[1].usedFraction, 0.46444, accuracy: 0.0001)
        XCTAssertEqual(limits[0].usedPercentRounded, 30)
        XCTAssertEqual(limits[1].usedPercentRounded, 46)
        // billingCycleEnd "1792587043000" millis = 2026-10-21T12:50:43Z.
        XCTAssertEqual(TestDates.iso8601(limits[0].resetsAt), "2026-10-21T12:50:43Z")
        XCTAssertEqual(TestDates.iso8601(limits[1].resetsAt), "2026-10-21T12:50:43Z")
    }

    // MARK: - 2. Request shape: Connect RPC headers plus empty JSON body

    func test_request_sendsConnectHeadersAndEmptyBody() async throws {
        let (provider, spy) = try provider(fixture: "cursor-current-period-basic.json")

        _ = try await provider.fetchLimits()

        let request = try XCTUnwrap(spy.lastRequest)
        XCTAssertEqual(request.url, CursorUsageProvider.usageURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-cursor-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }

    // MARK: - 3. Start plan without the API pool still renders both rows

    func test_startPlanWithoutApi_rendersBothRowsWithNotIncluded() async throws {
        let (provider, _) = try provider(fixture: "cursor-start-plan-no-api.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits.map(\.name), ["Cursor Auto", "Cursor API (not included)"])
        XCTAssertEqual(limits[0].usedPercentRounded, 13)
        XCTAssertEqual(limits[1].usedPercentRounded, 0)
    }

    // MARK: - 4. Out-of-range percents clamp to 0...1

    func test_outOfRangePercents_clampToValidFractions() async throws {
        let (provider, _) = try provider(fixture: "cursor-out-of-range.json")

        let limits = try await provider.fetchLimits()

        XCTAssertEqual(limits[0].usedFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(limits[1].usedFraction, 0.0, accuracy: 0.0001)
    }

    // MARK: - 5. Unrecognized payload is a visible failure, not silent zeros

    func test_unrecognizedPayload_throwsUnexpectedResponse() async throws {
        let (provider, _) = try provider(fixture: "cursor-unrecognized.json")

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Unexpected response from Cursor usage service"))
        }
    }

    // MARK: - 6. Malformed JSON is a visible failure

    func test_malformedJson_throwsUnexpectedResponse() async throws {
        let data = Data("<html>Just a moment...</html>".utf8)
        let spy = SpyTransport(data: data, statusCode: 200)
        let provider = CursorUsageProvider(
            credentialsSource: StubCursorCredentialsSource(credentials: CursorCredentials(accessToken: "t", email: nil, planTier: nil, expiresAt: nil)),
            transport: spy.transport,
            now: { TestDates.capture }
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Unexpected response from Cursor usage service"))
        }
    }

    // MARK: - 7. Credential failure short-circuits before the network

    func test_missingCredentials_throwsNotConnectedWithoutNetworkCall() async throws {
        let data = try Fixture.data(named: "cursor-current-period-basic.json")
        let spy = SpyTransport(data: data, statusCode: 200)
        let provider = CursorUsageProvider(
            credentialsSource: StubCursorCredentialsSource(error: UsageProviderError.notConnected("Cursor is not signed in - open Cursor IDE and sign in")),
            transport: spy.transport,
            now: { TestDates.capture }
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Cursor is not signed in - open Cursor IDE and sign in"))
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - 8. Expired token short-circuits before the network

    func test_expiredToken_throwsExpiredWithoutNetworkCall() async throws {
        let data = try Fixture.data(named: "cursor-current-period-basic.json")
        let spy = SpyTransport(data: data, statusCode: 200)
        let expired = CursorCredentials(
            accessToken: "expired-token",
            email: nil,
            planTier: nil,
            expiresAt: TestDates.capture.addingTimeInterval(-3600)
        )
        let provider = CursorUsageProvider(
            credentialsSource: StubCursorCredentialsSource(credentials: expired),
            transport: spy.transport,
            now: { TestDates.capture }
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Cursor session expired - open Cursor to refresh it"))
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - 9. Status mapping

    func test_http401_throwsRejectedCredentials() async throws {
        let (provider, _) = try provider(fixture: "cursor-current-period-basic.json", statusCode: 401)

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Cursor rejected the saved credentials - sign in to Cursor again"))
        }
    }

    func test_http403_throwsRejectedCredentials() async throws {
        let (provider, _) = try provider(fixture: "cursor-current-period-basic.json", statusCode: 403)

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Cursor rejected the saved credentials - sign in to Cursor again"))
        }
    }

    func test_http500_throwsServiceError() async throws {
        let (provider, _) = try provider(fixture: "cursor-current-period-basic.json", statusCode: 500)

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Cursor usage service returned HTTP 500"))
        }
    }

    func test_transportThrow_throwsNetworkError() async throws {
        let provider = CursorUsageProvider(
            credentialsSource: StubCursorCredentialsSource(credentials: CursorCredentials(accessToken: "t", email: nil, planTier: nil, expiresAt: nil)),
            transport: FailingTransport.transport,
            now: { TestDates.capture }
        )

        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Network error - check your connection"))
        }
    }

    // MARK: - 10. Reset-date parsing edge cases

    func test_resetDate_parsesMillisString() {
        XCTAssertEqual(
            TestDates.iso8601(CursorUsageResponse.resetDate(fromMillisString: "1792587043000")),
            "2026-10-21T12:50:43Z"
        )
    }

    func test_resetDate_nilOnBlankOrGarbage() {
        XCTAssertNil(CursorUsageResponse.resetDate(fromMillisString: nil))
        XCTAssertNil(CursorUsageResponse.resetDate(fromMillisString: ""))
        XCTAssertNil(CursorUsageResponse.resetDate(fromMillisString: "not-a-number"))
        XCTAssertNil(CursorUsageResponse.resetDate(fromMillisString: "0"))
    }
}

/// A Cursor credentials source with no database behind it.
struct StubCursorCredentialsSource: CursorCredentialsSource {
    let result: Result<CursorCredentials, Error>

    init(credentials: CursorCredentials) {
        self.result = .success(credentials)
    }

    init(error: Error) {
        self.result = .failure(error)
    }

    func load() throws -> CursorCredentials {
        try result.get()
    }
}
