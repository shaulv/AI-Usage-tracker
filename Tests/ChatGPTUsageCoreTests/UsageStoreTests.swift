import XCTest
@testable import ChatGPTUsageCore

/// The never-stale rule is the whole product, so it gets its own tests rather
/// than being implied by the provider tests.
@MainActor
final class UsageStoreTests: XCTestCase {

    private struct StubProvider: UsageProvider {
        let id = "stub"
        let displayName = "Stub"
        let result: Result<[UsageLimit], Error>

        func fetchLimits() async throws -> [UsageLimit] {
            try result.get()
        }
    }

    private func store(
        provider: any UsageProvider,
        defaultsName: String = "UsageStoreTests-\(UUID().uuidString)"
    ) -> UsageStore {
        let defaults = UserDefaults(suiteName: defaultsName) ?? .standard
        defaults.removePersistentDomain(forName: defaultsName)
        return UsageStore(provider: provider, refreshInterval: 300, defaults: defaults)
    }

    func test_successfulRefresh_publishesLimitsAndOkState() async {
        let limits = [
            UsageLimit(name: "Weekly", usedFraction: 0.42, resetsAt: nil),
            UsageLimit(name: "Session (5h)", usedFraction: 0.06, resetsAt: nil),
        ]
        let store = store(provider: StubProvider(result: .success(limits)))

        await store.refresh()

        XCTAssertEqual(store.limits, limits)
        XCTAssertEqual(store.state, .ok)
        XCTAssertNotNil(store.lastUpdated)
    }

    func test_failedRefresh_discardsThePreviousLimits() async {
        let limits = [UsageLimit(name: "Weekly", usedFraction: 0.42, resetsAt: nil)]
        var shouldFail = false
        let provider = FlakyProvider(limits: limits, shouldFail: { shouldFail })
        let store = store(provider: provider)

        await store.refresh()
        XCTAssertEqual(store.limits?.count, 1)

        // This is the assertion that fails if the never-stale rule is removed.
        shouldFail = true
        await store.refresh()

        XCTAssertNil(store.limits, "a failed fetch must not leave the old numbers on screen")
        XCTAssertEqual(store.menuBarLabel, "--%")
        guard case .failed(let message) = store.state else {
            return XCTFail("expected a failed state, got \(store.state)")
        }
        XCTAssertEqual(message, "Codex session expired - run codex to refresh it")
    }

    func test_menuBarLabel_showsTheSelectedLimit() async {
        let limits = [
            UsageLimit(name: "Weekly", usedFraction: 0.42, resetsAt: nil),
            UsageLimit(name: "Session (5h)", usedFraction: 0.06, resetsAt: nil),
        ]
        let store = store(provider: StubProvider(result: .success(limits)))

        await store.refresh()

        // With no saved selection the first row wins.
        XCTAssertEqual(store.menuBarLabel, "42%")

        store.selectedLimitName = "Session (5h)"
        XCTAssertEqual(store.menuBarLabel, "6%")
    }

    func test_savedSelectionThatNoLongerExists_fallsBackToTheFirstLimit() async {
        let limits = [UsageLimit(name: "Weekly", usedFraction: 0.42, resetsAt: nil)]
        let store = store(provider: StubProvider(result: .success(limits)))
        store.selectedLimitName = "A limit OpenAI renamed"

        await store.refresh()

        XCTAssertEqual(store.selectedLimit?.name, "Weekly")
        XCTAssertEqual(store.menuBarLabel, "42%")
    }

    func test_emptyResult_showsNoLabelButStaysOk() async {
        let store = store(provider: StubProvider(result: .success([])))

        await store.refresh()

        XCTAssertEqual(store.limits, [])
        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(store.menuBarLabel, "--%")
    }

    func test_refreshInterval_isFlooredAtFiveMinutes() {
        let store = UsageStore(
            provider: StubProvider(result: .success([])),
            refreshInterval: 1,
            defaults: UserDefaults(suiteName: "UsageStoreTests-floor") ?? .standard
        )

        XCTAssertEqual(store.effectiveRefreshInterval, 300)
        XCTAssertGreaterThanOrEqual(UsageStore.minimumRefreshInterval, 300)
    }

    func test_selectionIsPersisted() async {
        let suiteName = "UsageStoreTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let provider = StubProvider(result: .success([
            UsageLimit(name: "Weekly", usedFraction: 0.42, resetsAt: nil)
        ]))

        let first = UsageStore(provider: provider, refreshInterval: 300, defaults: defaults)
        await first.refresh()
        first.selectedLimitName = "Weekly"

        let second = UsageStore(provider: provider, refreshInterval: 300, defaults: defaults)
        XCTAssertEqual(second.selectedLimitName, "Weekly")

        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A provider whose behavior a test can flip mid-flight, so the same store
/// instance can be observed before and after a failure.
private struct FlakyProvider: UsageProvider {
    let id = "flaky"
    let displayName = "Flaky"
    let limits: [UsageLimit]
    let shouldFail: () -> Bool

    func fetchLimits() async throws -> [UsageLimit] {
        if shouldFail() {
            throw UsageProviderError.notConnected("Codex session expired - run codex to refresh it")
        }
        return limits
    }
}
