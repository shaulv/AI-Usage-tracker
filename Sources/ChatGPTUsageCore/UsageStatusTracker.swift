import Foundation

/// Represents a state transition when quota usage crosses into warning or critical.
public struct StatusTransitionEvent: Equatable, Sendable {
    public let providerId: String
    public let limitName: String
    public let previousLevel: UsageStatusLevel
    public let newLevel: UsageStatusLevel
    public let remainingPercent: Int
    public let resetsAt: Date?

    public init(
        providerId: String,
        limitName: String,
        previousLevel: UsageStatusLevel,
        newLevel: UsageStatusLevel,
        remainingPercent: Int,
        resetsAt: Date?
    ) {
        self.providerId = providerId
        self.limitName = limitName
        self.previousLevel = previousLevel
        self.newLevel = newLevel
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

/// Pure state machine tracking the status level of each usage limit over time.
///
/// Ensures edge-triggered alert behavior:
/// - Emits transition events ONLY when a limit escalates to a worse level (e.g. ok -> warning, warning -> critical).
/// - When usage improves (e.g. quota reset), the tracked level recovers silently to .ok without notifying,
///   re-arming the trigger for the next escalation.
public struct UsageStatusTracker: Sendable {
    private var history: [String: UsageStatusLevel] = [:]

    public init() {}

    /// Evaluates fresh limits for a given provider and returns any transition events.
    ///
    /// - Parameters:
    ///   - providerId: Provider identifier (e.g., "chatgpt", "claude", "cursor", "antigravity").
    ///   - limits: Current usage limits reported by the provider.
    ///   - config: Active threshold configuration.
    /// - Returns: List of transitions where status escalated to a higher severity level.
    public mutating func evaluate(
        providerId: String,
        limits: [UsageLimit],
        config: ThresholdConfiguration
    ) -> [StatusTransitionEvent] {
        var events: [StatusTransitionEvent] = []

        for limit in limits {
            let key = "\(providerId):\(limit.name)"
            let currentRemaining = limit.remainingPercentRounded
            let newLevel = UsageStatusEvaluator.evaluate(remainingPercent: currentRemaining, config: config)
            let previousLevel = history[key] ?? .ok

            if newLevel > previousLevel {
                events.append(StatusTransitionEvent(
                    providerId: providerId,
                    limitName: limit.name,
                    previousLevel: previousLevel,
                    newLevel: newLevel,
                    remainingPercent: currentRemaining,
                    resetsAt: limit.resetsAt
                ))
            }

            // Always update history to current level
            history[key] = newLevel
        }

        return events
    }

    /// Clears all historical status tracking.
    public mutating func reset() {
        history.removeAll()
    }
}
