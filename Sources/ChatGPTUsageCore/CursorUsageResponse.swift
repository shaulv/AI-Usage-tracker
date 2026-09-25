import Foundation

/// Decodable mirror of
/// `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`.
///
/// Only the keys this app needs are declared; `spendLimitUsage`,
/// `displayThreshold`, `displayMessage`, and the per-model event endpoints are
/// dropped for free by plain `Decodable`. Spend and on-demand dollars are a
/// different product concern (locked decision Q4: ignored for v1).
///
/// Cycle dates arrive as unix MILLISECONDS encoded as strings (for example
/// `"1771077734000"`). Usage percents arrive as numbers. All three percent
/// fields are optional: the Start plan omits the API pool, and a future shape
/// change must surface as a visible failure, not a silent zero.
struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: PlanUsage?

    enum CodingKeys: String, CodingKey {
        case billingCycleStart
        case billingCycleEnd
        case planUsage
    }

    /// False when nothing in the payload is recognizable at all. This is the
    /// difference between "this pool is not included in the plan" (a real
    /// answer, one row still renders) and "the endpoint changed under us"
    /// (a failure to report honestly).
    var hasRecognizedPayload: Bool {
        billingCycleStart != nil
            || billingCycleEnd != nil
            || planUsage?.hasRecognizedFields == true
    }

    struct PlanUsage: Decodable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
        let limit: Double?
        let remaining: Double?

        var hasRecognizedFields: Bool {
            autoPercentUsed != nil
                || apiPercentUsed != nil
                || totalPercentUsed != nil
                || limit != nil
                || remaining != nil
        }
    }

    /// Always emits both monthly rows in stable order (Auto then API), so the
    /// panel never shows a half. A pool the plan does not include renders at
    /// zero with a "(not included)" suffix instead of vanishing: locked Q3.
    /// Both rows share one reset date from `billingCycleEnd` (locked scope).
    /// `now` is unused today but kept so the signature matches the ChatGPT
    /// mapper and a future fallback path stays testable without a clock.
    func toUsageLimits(now: Date = Date()) -> [UsageLimit] {
        let resetAt = Self.resetDate(fromMillisString: billingCycleEnd)
        let auto = planUsage?.autoPercentUsed
        let api = planUsage?.apiPercentUsed
        let limits = [
            UsageLimit(
                name: auto != nil ? "Cursor Auto" : "Cursor Auto (not included)",
                usedFraction: UsageWindow(usedPercent: auto ?? 0, windowSeconds: nil, resetAfterSeconds: nil, resetAtEpochSeconds: nil).usedFraction,
                resetsAt: resetAt
            ),
            UsageLimit(
                name: api != nil ? "Cursor API" : "Cursor API (not included)",
                usedFraction: UsageWindow(usedPercent: api ?? 0, windowSeconds: nil, resetAfterSeconds: nil, resetAtEpochSeconds: nil).usedFraction,
                resetsAt: resetAt
            ),
        ]
        return UsageLimit.uniqued(limits)
    }

    /// Parses a millis-since-epoch string to a Date. Nil on empty, blank, or
    /// non-numeric input: a missing reset date hides the reset line, it never
    /// fails the whole fetch.
    static func resetDate(fromMillisString millis: String?) -> Date? {
        guard let millis else { return nil }
        let trimmed = millis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
