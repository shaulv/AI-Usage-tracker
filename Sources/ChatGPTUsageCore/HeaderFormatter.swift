import Foundation

/// What the menu-bar status item shows. Chosen by the user from the right-click
/// settings menu and persisted across launches.
public enum HeaderStyle: String, CaseIterable, Codable {
    /// `6%` — the session window only, the number people actually watch.
    case sessionOnly
    /// `S6% W47%` — session and weekly side by side; `S` = session, `W` = weekly.
    case sessionWeekly

    public var displayName: String {
        switch self {
        case .sessionOnly: return "Session limit"
        case .sessionWeekly: return "Session + weekly"
        }
    }
}

/// Pure string formatting for the menu bar. Lives in core so the exact bytes
/// the user sees are unit-tested without an NSStatusItem on the machine.
public enum HeaderFormatter {
    /// `percents` are rounded percents; nil renders as `--` so a missing or
    /// failed window is honestly unknown rather than a stale zero.
    public static func title(style: HeaderStyle, sessionPercent: Int?, weeklyPercent: Int?) -> String {
        let session = sessionPercent.map { "\($0)%" } ?? "--%"
        switch style {
        case .sessionOnly:
            return session
        case .sessionWeekly:
            let s = sessionPercent.map { "\($0)" } ?? "--"
            let w = weeklyPercent.map { "\($0)" } ?? "--"
            return "S\(s)% W\(w)%"
        }
    }
}

/// Finds the session and weekly rows in a provider's limits by the same
/// duration-derived names the namer produces, so both providers flow through
/// one lookup. Falls back to "no such window" rather than guessing.
public enum UsageWindowLookup {
    public static func sessionPercent(in limits: [UsageLimit]) -> Int? {
        guard let session = limits.first(where: { $0.name.hasPrefix("Session") }) else { return nil }
        return session.usedPercentRounded
    }

    public static func weeklyPercent(in limits: [UsageLimit]) -> Int? {
        guard let weekly = limits.first(where: { $0.name == "Weekly" }) else { return nil }
        return weekly.usedPercentRounded
    }

    /// Remaining-side views of the same lookups, so the menu bar can report how
    /// much is left without duplicating the by-name discovery.
    public static func sessionRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let session = limits.first(where: { $0.name.hasPrefix("Session") }) else { return nil }
        return session.remainingPercentRounded
    }

    public static func weeklyRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let weekly = limits.first(where: { $0.name == "Weekly" }) else { return nil }
        return weekly.remainingPercentRounded
    }
}
