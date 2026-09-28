import XCTest
@testable import ChatGPTUsageCore

/// Grok provider: one weekly row from GetSandUsageStatus, full sand header set,
/// checksum format, and the same failure contract as every other provider.
/// Every test runs against an injected transport and stub credentials. No test
/// touches the network, the secrets file, or the Keychain.
final class GrokUsageProviderTests: XCTestCase {

    private func provider(
        fixture: String,
        statusCode: Int = 200,
        credentials: GrokCredentials? = nil
    ) throws -> (GrokUsageProvider, SpyTransport) {
        let data = try Fixture.data(named: fixture)
        let spy = SpyTransport(data: data, statusCode: statusCode)
        let credentials = credentials ?? GrokCredentials(
            accessToken: "fake-grok-jwt",
            machineId: "fake-machine-id",
            email: nil,
            expiresAt: nil
        )
        let provider = GrokUsageProvider(
            credentialsSource: StubGrokCredentialsSource(credentials: credentials),
            transport: spy.transport,
            now: { TestDates.capture }
        )
        return (provider, spy)
    }

    // MARK: - 1. Weekly payload maps one row with the server reset date

    func test_weeklyPayload_mapsSingleWeeklyRow() async throws {
        let (provider, _) = try provider(fixture: "grok-sand-usage-weekly.json")
        let limits = try await provider.fetchLimits()
        XCTAssertEqual(limits.map(\.name), ["Weekly"])
        XCTAssertEqual(limits[0].usedPercentRounded, 12)
        XCTAssertEqual(TestDates.iso8601(limits[0].resetsAt), "2026-10-01T23:14:29Z")
    }

    // MARK: - 2. Request shape: sand headers plus checksum and empty body

    func test_request_sendsSandHeadersAndEmptyBody() async throws {
        let (provider, spy) = try provider(fixture: "grok-sand-usage-weekly.json")
        _ = try await provider.fetchLimits()
        let request = try XCTUnwrap(spy.lastRequest)
        XCTAssertEqual(request.url, GrokUsageProvider.usageURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-grok-jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cursor-client-type"), "sand")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cursor-client-source"), "sand-desktop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cursor-client-version"), "0.61.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-sand-box-namespace"), "prod")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-cursor-client-os"), "CLIENT_OS_MACOS")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ghost-mode"), "true")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-request-id"))
        let checksum = try XCTUnwrap(request.value(forHTTPHeaderField: "x-cursor-checksum"))
        XCTAssertTrue(checksum.hasSuffix("fake-machine-id"))
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }

    // MARK: - 3. Checksum is deterministic per timestamp

    func test_checksum_prefixIsStableForFixedDate() {
        let fixed = Date(timeIntervalSince1970: 1_790_633_400)
        let first = GrokUsageProvider.checksum(machineId: "mid", now: fixed)
        let second = GrokUsageProvider.checksum(machineId: "mid", now: fixed)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasSuffix("mid"))
        XCTAssertTrue(first.count > 3 + "mid".count)
    }

    // MARK: - 4. No metered percent is an honest empty, not a failure

    func test_noPercent_returnsEmptyList() async throws {
        let (provider, _) = try provider(fixture: "grok-sand-usage-no-percent.json")
        let limits = try await provider.fetchLimits()
        XCTAssertTrue(limits.isEmpty)
    }

    // MARK: - 5. Unrecognized payload is a fetch failure

    func test_unrecognizedPayload_throwsFetchFailed() async throws {
        let (provider, _) = try provider(fixture: "grok-sand-usage-unrecognized.json")
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Unexpected response from Grok usage service"))
        }
    }

    // MARK: - 6. Non-JSON body is a fetch failure

    func test_nonJsonBody_throwsFetchFailed() async throws {
        let spy = SpyTransport(data: Data("<html>nope</html>".utf8), statusCode: 200)
        let provider = GrokUsageProvider(
            credentialsSource: StubGrokCredentialsSource(credentials: GrokCredentials(accessToken: "t", machineId: "m", email: nil, expiresAt: nil)),
            transport: spy.transport,
            now: { TestDates.capture }
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Unexpected response from Grok usage service"))
        }
    }

    // MARK: - 7. Credential errors propagate, expired never hits network

    func test_credentialsError_propagates() async throws {
        let spy = SpyTransport(data: Data("{}".utf8), statusCode: 200)
        let provider = GrokUsageProvider(
            credentialsSource: StubGrokCredentialsSource(error: UsageProviderError.notConnected("Grok Bot is not signed in - open Grok Bot and sign in")),
            transport: spy.transport,
            now: { TestDates.capture }
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Grok Bot is not signed in - open Grok Bot and sign in"))
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    func test_expiredCredentials_neverHitsNetwork() async throws {
        let (provider, spy) = try provider(
            fixture: "grok-sand-usage-weekly.json",
            credentials: GrokCredentials(accessToken: "t", machineId: "m", email: nil, expiresAt: Date(timeIntervalSince1970: 1000))
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Grok session expired - open Grok Bot to refresh it"))
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - 8. Status mapping

    func test_http401_throwsRejectedCredentials() async throws {
        let (provider, _) = try provider(fixture: "grok-sand-usage-weekly.json", statusCode: 401)
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Grok rejected the saved credentials - sign in to Grok Bot again"))
        }
    }

    func test_http403_throwsRejectedCredentials() async throws {
        let (provider, _) = try provider(fixture: "grok-sand-usage-weekly.json", statusCode: 403)
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected notConnected")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .notConnected("Grok rejected the saved credentials - sign in to Grok Bot again"))
        }
    }

    func test_http500_throwsServiceError() async throws {
        let (provider, _) = try provider(fixture: "grok-sand-usage-weekly.json", statusCode: 500)
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected fetchFailed")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .fetchFailed("Grok usage service returned HTTP 500"))
        }
    }

    func test_transportThrow_throwsNetworkError() async throws {
        let provider = GrokUsageProvider(
            credentialsSource: StubGrokCredentialsSource(credentials: GrokCredentials(accessToken: "t", machineId: "m", email: nil, expiresAt: nil)),
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
}

/// A Grok credentials source with no secrets file or Keychain behind it.
struct StubGrokCredentialsSource: GrokCredentialsSource {
    let result: Result<GrokCredentials, Error>
    init(credentials: GrokCredentials) {
        self.result = .success(credentials)
    }
    init(error: Error) {
        self.result = .failure(error)
    }
    func load() throws -> GrokCredentials {
        try result.get()
    }
}
