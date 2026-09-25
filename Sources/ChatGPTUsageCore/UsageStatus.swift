import Foundation

/// Three status levels for an AI usage quota window.
///
/// Derived from the percentage of usage LEFT (remaining percent, 0...100).
/// Ordered by severity: ok < warning < critical.
public enum UsageStatusLevel: String, Codable, Comparable, CaseIterable, Sendable {
    /// Plenty of quota left (> warningRemainingPercent). Displayed in green.
    case ok
    /// Quota is running low (<= warningRemainingPercent). Displayed in orange.
    case warning
    /// Quota is very low or exhausted (<= criticalRemainingPercent). Displayed in red.
    case critical

    public static func < (lhs: UsageStatusLevel, rhs: UsageStatusLevel) -> Bool {
        let rank: [UsageStatusLevel: Int] = [.ok: 0, .warning: 1, .critical: 2]
        return rank[lhs]! < rank[rhs]!
    }
}

/// User-configurable thresholds defining when usage status transitions from
/// ok to warning (orange) and critical (red alert).
///
/// Thresholds represent the percentage of quota LEFT (0...100).
/// Invariant: 0 <= criticalRemainingPercent < warningRemainingPercent <= 100.
public struct ThresholdConfiguration: Equatable, Codable, Sendable {
    /// Default warning threshold: 20% quota remaining.
    public static let defaultWarningRemainingPercent = 20
    /// Default critical threshold: 10% quota remaining.
    public static let defaultCriticalRemainingPercent = 10

    public var warningRemainingPercent: Int
    public var criticalRemainingPercent: Int

    public init(warningRemainingPercent: Int = defaultWarningRemainingPercent,
                criticalRemainingPercent: Int = defaultCriticalRemainingPercent) {
        // Enforce 1 <= critical < warning <= 99 to ensure meaningful bands
        let clampedCritical = max(1, min(criticalRemainingPercent, 98))
        let clampedWarning = max(clampedCritical + 1, min(warningRemainingPercent, 99))
        self.criticalRemainingPercent = clampedCritical
        self.warningRemainingPercent = clampedWarning
    }
}

/// Pure evaluation function mapping remaining percentage to a status level.
public enum UsageStatusEvaluator {
    /// Evaluates the status level for a given percentage of usage left.
    ///
    /// - Parameters:
    ///   - remainingPercent: The quota remaining as an integer 0...100.
    ///   - config: The active threshold configuration.
    /// - Returns: `.critical` if remaining <= critical, `.warning` if remaining <= warning, else `.ok`.
    public static func evaluate(remainingPercent: Int, config: ThresholdConfiguration) -> UsageStatusLevel {
        if remainingPercent <= config.criticalRemainingPercent {
            return .critical
        } else if remainingPercent <= config.warningRemainingPercent {
            return .warning
        } else {
            return .ok
        }
    }
}
