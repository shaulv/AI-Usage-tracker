import Foundation
import XCTest
@testable import ChatGPTUsageCore

final class UsageStatusEngineTests: XCTestCase {

    // MARK: - UsageStatusEvaluator Tests

    func test_evaluate_returnsOk_whenRemainingAboveWarning() {
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let status = UsageStatusEvaluator.evaluate(remainingPercent: 25, config: config)
        XCTAssertEqual(status, .ok)
    }

    func test_evaluate_returnsWarning_whenRemainingAtWarning() {
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let status = UsageStatusEvaluator.evaluate(remainingPercent: 20, config: config)
        XCTAssertEqual(status, .warning)
    }

    func test_evaluate_returnsWarning_whenRemainingBetweenWarningAndCritical() {
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let status = UsageStatusEvaluator.evaluate(remainingPercent: 15, config: config)
        XCTAssertEqual(status, .warning)
    }

    func test_evaluate_returnsCritical_whenRemainingAtCritical() {
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let status = UsageStatusEvaluator.evaluate(remainingPercent: 10, config: config)
        XCTAssertEqual(status, .critical)
    }

    func test_evaluate_returnsCritical_whenRemainingBelowCritical() {
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let status = UsageStatusEvaluator.evaluate(remainingPercent: 5, config: config)
        XCTAssertEqual(status, .critical)
    }

    func test_evaluate_returnsCritical_whenRemainingZero() {
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let status = UsageStatusEvaluator.evaluate(remainingPercent: 0, config: config)
        XCTAssertEqual(status, .critical)
    }

    // MARK: - ThresholdConfiguration Invariants

    func test_thresholdConfiguration_enforcesCriticalLessThanWarning() {
        let config = ThresholdConfiguration(warningRemainingPercent: 15, criticalRemainingPercent: 20)
        XCTAssertLessThan(config.criticalRemainingPercent, config.warningRemainingPercent)
        XCTAssertEqual(config.criticalRemainingPercent, 20)
        XCTAssertEqual(config.warningRemainingPercent, 21)
    }

    func test_thresholdConfiguration_clampsBounds() {
        let lowConfig = ThresholdConfiguration(warningRemainingPercent: 0, criticalRemainingPercent: -5)
        XCTAssertGreaterThanOrEqual(lowConfig.criticalRemainingPercent, 1)
        XCTAssertGreaterThan(lowConfig.warningRemainingPercent, lowConfig.criticalRemainingPercent)

        let highConfig = ThresholdConfiguration(warningRemainingPercent: 150, criticalRemainingPercent: 120)
        XCTAssertLessThanOrEqual(highConfig.warningRemainingPercent, 99)
        XCTAssertLessThan(highConfig.criticalRemainingPercent, highConfig.warningRemainingPercent)
    }

    // MARK: - UsageStatusTracker State Machine

    func test_tracker_emitsWarning_onInitialCrossing() {
        var tracker = UsageStatusTracker()
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)
        let limit = UsageLimit(name: "Session", usedFraction: 0.85, resetsAt: nil)

        let events = tracker.evaluate(providerId: "claude", limits: [limit], config: config)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.providerId, "claude")
        XCTAssertEqual(events.first?.limitName, "Session")
        XCTAssertEqual(events.first?.previousLevel, .ok)
        XCTAssertEqual(events.first?.newLevel, .warning)
        XCTAssertEqual(events.first?.remainingPercent, 15)
    }

    func test_tracker_doesNotEmitDuplicate_whileRemainingInSameStatus() {
        var tracker = UsageStatusTracker()
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)

        let limit1 = UsageLimit(name: "Session", usedFraction: 0.85, resetsAt: nil)
        _ = tracker.evaluate(providerId: "claude", limits: [limit1], config: config)

        let limit2 = UsageLimit(name: "Session", usedFraction: 0.88, resetsAt: nil)
        let events = tracker.evaluate(providerId: "claude", limits: [limit2], config: config)

        XCTAssertTrue(events.isEmpty)
    }

    func test_tracker_emitsCritical_whenCrossingFromWarningToCritical() {
        var tracker = UsageStatusTracker()
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)

        let limit1 = UsageLimit(name: "Session", usedFraction: 0.85, resetsAt: nil)
        _ = tracker.evaluate(providerId: "claude", limits: [limit1], config: config)

        let limit2 = UsageLimit(name: "Session", usedFraction: 0.95, resetsAt: nil)
        let events = tracker.evaluate(providerId: "claude", limits: [limit2], config: config)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.previousLevel, .warning)
        XCTAssertEqual(events.first?.newLevel, .critical)
        XCTAssertEqual(events.first?.remainingPercent, 5)
    }

    func test_tracker_emitsCritical_whenPlummetingDirectlyFromOk() {
        var tracker = UsageStatusTracker()
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)

        let limit = UsageLimit(name: "Session", usedFraction: 0.95, resetsAt: nil)
        let events = tracker.evaluate(providerId: "claude", limits: [limit], config: config)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.previousLevel, .ok)
        XCTAssertEqual(events.first?.newLevel, .critical)
        XCTAssertEqual(events.first?.remainingPercent, 5)
    }

    func test_tracker_clearsSilently_onQuotaReset() {
        var tracker = UsageStatusTracker()
        let config = ThresholdConfiguration(warningRemainingPercent: 20, criticalRemainingPercent: 10)

        let exhausted = UsageLimit(name: "Session", usedFraction: 0.95, resetsAt: nil)
        _ = tracker.evaluate(providerId: "claude", limits: [exhausted], config: config)

        let resetLimit = UsageLimit(name: "Session", usedFraction: 0.0, resetsAt: nil)
        let resetEvents = tracker.evaluate(providerId: "claude", limits: [resetLimit], config: config)

        XCTAssertTrue(resetEvents.isEmpty)

        let lowLimit = UsageLimit(name: "Session", usedFraction: 0.85, resetsAt: nil)
        let nextEvents = tracker.evaluate(providerId: "claude", limits: [lowLimit], config: config)

        XCTAssertEqual(nextEvents.count, 1)
        XCTAssertEqual(nextEvents.first?.previousLevel, .ok)
        XCTAssertEqual(nextEvents.first?.newLevel, .warning)
    }
}
