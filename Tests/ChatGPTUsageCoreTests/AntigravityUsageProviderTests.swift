import Foundation
import XCTest
@testable import ChatGPTUsageCore

/// Antigravity contract tests, built from the language server payload captured
/// live on 24/09/2026: `response.groups[].buckets[]` with `window` and
/// `remainingFraction` (remaining, not used).
final class AntigravityUsageProviderTests: XCTestCase {

    // MARK: - Mapping (fixtures)

    func test_summary_mapsBothPoolsAndBothWindows() throws {
        let data = try Fixture.data(named: "antigravity-quota-summary.json")
        let limits = try AntigravityUsageMapper.limits(from: data)
        XCTAssertEqual(limits.map(\.name), [
            "Gemini Session", "Gemini Weekly", "Third-party Session", "Third-party Weekly",
        ])
        XCTAssertEqual(limits.map(\.usedPercentRounded), [9, 19, 100, 34])
        XCTAssertEqual(
            limits.first { $0.name == "Gemini Weekly" }?.resetsAt,
            AntigravityQuotaSummary.parseReset("2026-09-30T13:51:30Z")
        )
    }

    func test_fiveHourOnlyPayload_producesSessionRowsOnly() throws {
        let data = try Fixture.data(named: "antigravity-quota-5h-only.json")
        let limits = try AntigravityUsageMapper.limits(from: data)
        XCTAssertEqual(limits.map(\.name), ["Gemini Session", "Third-party Session"])
        XCTAssertEqual(limits.map(\.usedPercentRounded), [50, 75])
    }

    func test_bucketWithoutRemainingFraction_isNotARow() throws {
        let summary = try decode(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","resetTime":"2026-09-24T23:08:04Z"}]}]}}"#)
        XCTAssertEqual(summary.toUsageLimits(), [])
    }

    func test_missingWindowField_fallsBackToTheResetDelta() throws {
        let weekly = try decode(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-x","remainingFraction":0.5,"resetTime":"2026-10-05T00:00:00Z"}]}]}}"#)
        let session = try decode(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-x","remainingFraction":0.5,"resetTime":"2026-09-24T22:00:00Z"}]}]}}"#)
        let now = try XCTUnwrap(AntigravityQuotaSummary.parseReset("2026-09-24T18:00:00Z"))
        XCTAssertEqual(weekly.toUsageLimits(now: now).map(\.name), ["Gemini Weekly"])
        XCTAssertEqual(session.toUsageLimits(now: now).map(\.name), ["Gemini Session"])
    }

    func test_worstRemainingWinsWithinOneRow() throws {
        let summary = try decode(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.9},{"bucketId":"gemini-flash-5h","window":"5h","remainingFraction":0.4}]}]}}"#)
        let limits = summary.toUsageLimits()
        XCTAssertEqual(limits.map(\.name), ["Gemini Session"])
        XCTAssertEqual(limits.first?.usedPercentRounded, 60)
    }

    func test_unrecognizedPayload_throwsFetchFailed() {
        let data = Data(#"{"unexpected":"shape"}"#.utf8)
        XCTAssertThrowsError(try AntigravityUsageMapper.limits(from: data)) { error in
            XCTAssertEqual(
                assertProviderError(error)?.message,
                "Unexpected response from Antigravity usage service"
            )
        }
    }

    func test_htmlBody_throwsFetchFailed() {
        let data = Data("<!DOCTYPE html><html>hi</html>".utf8)
        XCTAssertThrowsError(try AntigravityUsageMapper.limits(from: data)) { error in
            XCTAssertEqual(
                assertProviderError(error)?.message,
                "Unexpected response from Antigravity usage service"
            )
        }
    }

    // MARK: - Provider behavior (injected transport + session stub)

    private func makeProvider(
        session: Result<AntigravitySession, Error>,
        transport: @escaping ChatGPTUsageProvider.Transport
    ) -> AntigravityUsageProvider {
        AntigravityUsageProvider(
            sessionSource: StubAntigravitySessionSource(result: session),
            transport: transport,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    private func liveSession(ports: [Int] = [49433]) -> AntigravitySession {
        AntigravitySession(processId: 1357, csrfToken: "FORCED-CSRF", candidatePorts: ports)
    }

    private func summaryData() throws -> Data {
        try Fixture.data(named: "antigravity-quota-summary.json")
    }

    func test_request_postsToLoopbackWithTheCSRFHeader() throws {
        let request = AntigravityUsageProvider.makeRequest(session: liveSession(), port: 49433)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://127.0.0.1:49433/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "FORCED-CSRF")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func test_deadFirstPort_fallsThroughToTheSecond() async throws {
        let spy = SequencedTransport([
            .failure(URLError(.cannotConnectToHost)),
            .success((try summaryData(), 200)),
        ])
        let provider = makeProvider(
            session: .success(liveSession(ports: [49434, 49433])),
            transport: spy.transport
        )
        let limits = try await provider.fetchLimits()
        XCTAssertEqual(limits.count, 4)
        XCTAssertEqual(spy.requests.count, 2)
        XCTAssertEqual(spy.requests.last?.url?.port, 49433)
    }

    func test_http401_isNotConnectedAndStopsImmediately() async {
        let spy = SequencedTransport([.success((Data("{}".utf8), 401))])
        let provider = makeProvider(
            session: .success(liveSession(ports: [49433, 49434])),
            transport: spy.transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            XCTAssertEqual(
                assertProviderError(error)?.message,
                "Antigravity rejected the local session - restart Antigravity IDE"
            )
        }
        XCTAssertEqual(spy.requests.count, 1)
    }

    func test_everyPortFailing_isFetchFailedWithTheStatusCode() async {
        let spy = SequencedTransport([
            .failure(URLError(.cannotConnectToHost)),
            .success((Data("{}".utf8), 500)),
        ])
        let provider = makeProvider(
            session: .success(liveSession(ports: [49434, 49433])),
            transport: spy.transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a fetchFailed error")
        } catch {
            XCTAssertEqual(
                assertProviderError(error)?.message,
                "Antigravity usage service returned HTTP 500"
            )
        }
        XCTAssertEqual(spy.requests.count, 2)
    }

    func test_noSession_reportsThatTheIDENotRunning() async {
        let provider = makeProvider(
            session: .failure(UsageProviderError.notConnected(
                "Antigravity IDE is not running - open it to read Gemini usage"
            )),
            transport: SequencedTransport([]).transport
        )
        do {
            _ = try await provider.fetchLimits()
            XCTFail("expected a notConnected error")
        } catch {
            XCTAssertEqual(
                assertProviderError(error)?.message,
                "Antigravity IDE is not running - open it to read Gemini usage"
            )
        }
    }

    func test_provider_idIsStable() {
        XCTAssertEqual(AntigravityUsageProvider().id, "antigravity")
        XCTAssertEqual(AntigravityUsageProvider().displayName, "Gemini")
    }

    private func decode(_ json: String) throws -> AntigravityQuotaSummary {
        try JSONDecoder().decode(AntigravityQuotaSummary.self, from: Data(json.utf8))
    }
}

/// A session source with no process behind it.
private struct StubAntigravitySessionSource: AntigravitySessionSource {
    let result: Result<AntigravitySession, Error>
    func load() throws -> AntigravitySession { try result.get() }
}

/// Answers each call with the next queued outcome and records every request,
/// so the port-fallthrough path is assertable.
private final class SequencedTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<(Data, Int), Error>]
    private var recorded: [URLRequest] = []

    init(_ outcomes: [Result<(Data, Int), Error>]) { self.outcomes = outcomes }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    var transport: ChatGPTUsageProvider.Transport {
        { request in
            self.lock.lock()
            self.recorded.append(request)
            let outcome: Result<(Data, Int), Error>
            if self.outcomes.isEmpty {
                outcome = .failure(URLError(.cannotConnectToHost))
            } else {
                outcome = self.outcomes.removeFirst()
            }
            self.lock.unlock()

            switch outcome {
            case .success(let (data, statusCode)):
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://127.0.0.1:0")!,
                    statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }
}
