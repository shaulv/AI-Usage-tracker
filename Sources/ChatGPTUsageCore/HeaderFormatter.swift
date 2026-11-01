import Foundation

/// What the menu-bar status item shows. Chosen by the user from the right-click
/// settings menu and persisted across launches.
public enum HeaderStyle: String, CaseIterable, Codable {
    /// `6%` — the session window only, the number people actually watch.
    case sessionOnly
    /// `S6% W47%` — session and weekly side by side; `S` = session, `W` = weekly.
    case sessionWeekly
    /// `C70% A54%` — Cursor monthly pair; `C` = Cursor Auto left, `A` = Cursor API left.
    case cursorMonthly

    public var displayName: String {
        switch self {
        case .sessionOnly: return "Session limit"
        case .sessionWeekly: return "Session + weekly"
        case .cursorMonthly: return "Cursor Auto + API"
        }
    }
}

/// Which AI model/provider appears in the menu bar header. Chosen by the user
/// from the right-click settings menu or Preferences window and persisted across launches.
public enum HeaderProvider: String, CaseIterable, Codable {
    case auto = "auto"
    case chatGPT = "chatgpt"
    case claude = "claude"
    case gemini = "gemini"
    case cursor = "cursor"
    case grok = "grok"

    public var displayName: String {
        switch self {
        case .auto: return "Automatic (First Active)"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
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
        case .cursorMonthly:
            let c = sessionPercent.map { "\($0)" } ?? "--"
            let a = weeklyPercent.map { "\($0)" } ?? "--"
            return "C\(c)% A\(a)%"
        }
    }

    /// Cursor monthly pair: reuses the session/weekly slots so the header menu
    /// needs no new shape. Callers pass Auto-left as sessionPercent and
    /// API-left as weeklyPercent.
    public static func cursorTitle(autoLeft: Int?, apiLeft: Int?) -> String {
        title(style: .cursorMonthly, sessionPercent: autoLeft, weeklyPercent: apiLeft)
    }

    /// Grok weekly: reuses the session-only slot so the header menu needs no
    /// new shape. The single weekly row is the only number Grok reports.
    public static func grokTitle(weeklyLeft: Int?) -> String {
        title(style: .sessionOnly, sessionPercent: weeklyLeft, weeklyPercent: nil)
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

    /// Gemini-side views of the same lookups, over the fixed Antigravity row
    /// names. The Gemini rows carry a provider prefix by design (they share a
    /// panel with ChatGPT's own `Session` / `Weekly` rows), so they need
    /// their own discovery rather than reusing the unprefixed matchers.
    public static func geminiSessionPercent(in limits: [UsageLimit]) -> Int? {
        guard let session = limits.first(where: { $0.name == "Gemini Session" }) else { return nil }
        return session.usedPercentRounded
    }

    public static func geminiWeeklyPercent(in limits: [UsageLimit]) -> Int? {
        guard let weekly = limits.first(where: { $0.name == "Gemini Weekly" }) else { return nil }
        return weekly.usedPercentRounded
    }

    public static func geminiSessionRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let session = limits.first(where: { $0.name == "Gemini Session" }) else { return nil }
        return session.remainingPercentRounded
    }

    public static func geminiWeeklyRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let weekly = limits.first(where: { $0.name == "Gemini Weekly" }) else { return nil }
        return weekly.remainingPercentRounded
    }

    /// Cursor-side views over the fixed monthly row names. Matches the exact
    /// names first, then the "(not included)" suffixed variants, so a plan
    /// without the API pool still resolves its Auto row and honestly reports
    /// the missing side as nil (rendered `--` upstream).
    public static func cursorAutoPercent(in limits: [UsageLimit]) -> Int? {
        guard let row = limits.first(where: { $0.name.hasPrefix("Cursor Auto") }) else { return nil }
        if row.name.contains("not included") { return nil }
        return row.usedPercentRounded
    }

    public static func cursorApiPercent(in limits: [UsageLimit]) -> Int? {
        guard let row = limits.first(where: { $0.name.hasPrefix("Cursor API") }) else { return nil }
        if row.name.contains("not included") { return nil }
        return row.usedPercentRounded
    }

    public static func cursorAutoRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let row = limits.first(where: { $0.name.hasPrefix("Cursor Auto") }) else { return nil }
        if row.name.contains("not included") { return nil }
        return row.remainingPercentRounded
    }

    /// Grok-side views over the single weekly row name. The Grok row shares
    /// its `Weekly` name with ChatGPT's own weekly row by design (they never
    /// share a panel section lookup: each lookup runs over one provider's
    /// own limits), so no provider prefix is needed.
    public static func grokWeeklyPercent(in limits: [UsageLimit]) -> Int? {
        guard let weekly = limits.first(where: { $0.name == "Weekly" }) else { return nil }
        return weekly.usedPercentRounded
    }

    public static func grokWeeklyRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let weekly = limits.first(where: { $0.name == "Weekly" }) else { return nil }
        return weekly.remainingPercentRounded
    }

    public static func cursorApiRemainingPercent(in limits: [UsageLimit]) -> Int? {
        guard let row = limits.first(where: { $0.name.hasPrefix("Cursor API") }) else { return nil }
        if row.name.contains("not included") { return nil }
        return row.remainingPercentRounded
    }
}
