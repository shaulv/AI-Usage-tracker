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

    func test_refreshInterval_isFlooredAtOneMinute() {
        let store = UsageStore(
            provider: StubProvider(result: .success([])),
            refreshInterval: 1,
            defaults: UserDefaults(suiteName: "UsageStoreTests-floor") ?? .standard
        )

        // The idle cadence floor: 60s, per the adaptive-refresh spec.
        XCTAssertEqual(store.effectiveRefreshInterval, 60)
        XCTAssertEqual(UsageStore.minimumRefreshInterval, 60)
    }

    func test_refreshDelay_isTenSecondsInsideABurstWindow() {
        let open = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            UsageStore.refreshDelay(now: open.addingTimeInterval(30), burstDeadline: open.addingTimeInterval(60)),
            UsageStore.burstRefreshInterval
        )
    }

    func test_refreshDelay_isSixtySecondsOutsideABurstWindow() {
        let past = Date(timeIntervalSince1970: 1_000)
        // No burst at all, and a burst whose window has drained, both mean idle.
        XCTAssertEqual(UsageStore.refreshDelay(now: past, burstDeadline: nil), 60)
        XCTAssertEqual(
            UsageStore.refreshDelay(now: past.addingTimeInterval(61), burstDeadline: past.addingTimeInterval(60)),
            60
        )
    }

    func test_refreshDelay_usesTheConfiguredIdleInterval() {
        let past = Date(timeIntervalSince1970: 1_000)

        // The idle leg is the store's configured cadence, not a hardcoded
        // constant: asking for five minutes must actually produce five minutes.
        XCTAssertEqual(UsageStore.refreshDelay(now: past, burstDeadline: nil, idle: 300), 300)
        // An open burst window still wins over the configured idle cadence.
        XCTAssertEqual(
            UsageStore.refreshDelay(now: past, burstDeadline: past.addingTimeInterval(60), idle: 300),
            UsageStore.burstRefreshInterval
        )
        // The default keeps the documented 60s floor for every existing caller.
        XCTAssertEqual(
            UsageStore.refreshDelay(now: past, burstDeadline: nil),
            UsageStore.minimumRefreshInterval
        )
    }

    func test_movement_opensABurstWindow() async {
        var percent = 10.0
        let provider = MutableProvider { [
            UsageLimit(name: "Weekly", usedFraction: percent / 100, resetsAt: nil)
        ] }
        let base = Date(timeIntervalSince1970: 5_000)
        var offset: TimeInterval = 0
        let store = UsageStore(
            provider: provider,
            defaults: UserDefaults(suiteName: "UsageStoreTests-burst-\(UUID().uuidString)") ?? .standard,
            now: { base.addingTimeInterval(offset) }
        )

        // First success is the baseline: no burst yet.
        await store.refresh()
        XCTAssertNil(store.burstDeadline)

        // Same values next time: still no burst.
        await store.refresh()
        XCTAssertNil(store.burstDeadline)

        // A moved percentage opens the one-minute fast window.
        percent = 11.0
        offset = 100
        await store.refresh()
        XCTAssertEqual(store.burstDeadline, base.addingTimeInterval(100 + 60))
        XCTAssertEqual(
            UsageStore.refreshDelay(now: base.addingTimeInterval(110), burstDeadline: store.burstDeadline),
            10
        )
    }

    func test_failure_clearsTheBurstBaselineSoRecoveryIsNotMovement() async {
        var shouldFail = false
        let limits = [UsageLimit(name: "Weekly", usedFraction: 0.42, resetsAt: nil)]
        let provider = FlakyProvider(limits: limits, shouldFail: { shouldFail })
        let store = store(provider: provider)

        await store.refresh()   // baseline
        shouldFail = true
        await store.refresh()   // failure clears the baseline
        XCTAssertNil(store.burstDeadline)
        shouldFail = false
        await store.refresh()   // recovery must not read as movement
        XCTAssertNil(store.burstDeadline)
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

/// A provider whose payload a test can change between calls, which is the only
/// honest way to exercise "percentages moved" without the network.
private struct MutableProvider: UsageProvider {
    let id = "mutable"
    let displayName = "Mutable"
    let payload: () -> [UsageLimit]

    func fetchLimits() async throws -> [UsageLimit] {
        payload()
    }
}

