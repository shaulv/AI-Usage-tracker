import Foundation

/// One metered window as the server describes it.
///
/// `resetAt` is derived from `reset_at`, which the server sends as epoch
/// SECONDS. Not milliseconds, and not an ISO 8601 string. This was recomputed
/// against a captured payload: 1785024392 is 2026-07-26T00:06:32Z, and
/// 1785024392 - 589104 is 2026-07-19T04:28:08Z, which matches the stated
/// capture time. Treating it as milliseconds would put the reset in 1970.
public struct UsageWindow: Equatable {
    public let usedPercent: Double
    public let windowSeconds: Double?
    public let resetAfterSeconds: Double?
    public let resetAtEpochSeconds: Double?

    /// Clamped so a server bug or a future >100 reading cannot produce a
    /// fraction outside 0...1 anywhere downstream.
    public var usedFraction: Double {
        min(max(usedPercent, 0), 100) / 100
    }

    /// Reset instant, preferring the absolute `reset_at` and falling back to
    /// `now + reset_after_seconds` when the server omits it. `now` is injected
    /// so the fallback is testable without sleeping.
    public func resolvesResetAt(now: Date) -> Date? {
        if let epoch = resetAtEpochSeconds, epoch > 0 {
            return Date(timeIntervalSince1970: epoch)
        }
        if let remaining = resetAfterSeconds, remaining >= 0 {
            return now.addingTimeInterval(remaining)
        }
        return nil
    }
}

/// A named limit, ready for display. The unit the UI and the menu bar consume.
public struct UsageLimit: Equatable, Identifiable {
    public let name: String
    public let usedFraction: Double
    public let resetsAt: Date?

    public var id: String { name }

    public var usedPercentRounded: Int {
        Int((usedFraction * 100).rounded())
    }

    /// How much of this window is left, as an integer 0...100. Flips the percent
    /// the user sees from "used" to "left": 100 - usedPercentRounded, clamped so a
    /// server bug that produced >100 or <0 cannot yield a negative or >100
    /// remaining value.
    public var remainingPercentRounded: Int {
        min(max(100 - usedPercentRounded, 0), 100)
    }

    /// Names double as row identity in the panel, so they must be unique within
    /// one payload. Duration-derived naming can legitimately collide: a payload
    /// with two 5-hour windows produces "Session (5h)" twice, and duplicate
    /// SwiftUI identities are how a row silently renders as a copy of another
    /// (that is exactly the defect this fixes). Suffixing here, once, keeps every
    /// consumer honest without a second guard in the UI.
    public static func uniqued(_ limits: [UsageLimit]) -> [UsageLimit] {
        var seen: [String: Int] = [:]
        return limits.map { limit in
            let count = (seen[limit.name] ?? 0) + 1
            seen[limit.name] = count
            guard count > 1 else { return limit }
            return UsageLimit(
                name: "\(limit.name) (\(count))",
                usedFraction: limit.usedFraction,
                resetsAt: limit.resetsAt
            )
        }
    }
}

/// Everything that can go wrong, split by what the user must do about it.
///
/// `notConnected` always has a fix the user can perform (sign in, run codex).
/// `fetchFailed` is transient or a server-side break, and the honest response
/// is to say so rather than invent a number.
public enum UsageProviderError: Error, Equatable {
    case notConnected(String)
    case fetchFailed(String)

    public var message: String {
        switch self {
        case .notConnected(let message): return message
        case .fetchFailed(let message): return message
        }
    }
}

/// Window naming is derived from duration, never from position.
///
/// On the captured account the `primary_window` IS the weekly one and there is
/// no secondary. On Plus and Pro a 5-hour window exists too. So `primary` does
/// not mean "session", and hardcoding names by slot would mislabel accounts.
public enum WindowNamer {
    static let secondsPerHour: Double = 3600
    static let secondsPerDay: Double = 86400

    public static func name(forWindowSeconds seconds: Double?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }

        if seconds < secondsPerDay {
            let hours = seconds / secondsPerHour
            return "Session (\(Self.trimmed(hours))h)"
        }
        let days = seconds / secondsPerDay
        switch Int(days.rounded()) {
        case 7: return "Weekly"
        case 30: return "30-day"
        case 31: return "31-day"
        default: return "\(Int(days.rounded()))-day"
        }
    }

    /// 5 renders as "5", 2.5 renders as "2.5".
    private static func trimmed(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(value)
    }

    /// "codex_bengalfox" becomes "Codex bengalfox". Used only when the server
    /// sends a named entry with an empty `limit_name`.
    public static func humanize(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let spaced = cleaned.replacingOccurrences(of: "_", with: " ")
        let lowercased = spaced.lowercased()
        return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
    }
}
