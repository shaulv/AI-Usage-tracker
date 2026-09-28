import Foundation

/// Decodable mirror of
/// `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`.
///
/// This is the call Grok Bot's own profile screen makes (`fetchSandWeeklyUsage`
/// in the shipped bundle): one Connect RPC v1 POST with an empty JSON body,
/// authenticated with the decrypted session JWT. Read-only, consumes no quota.
///
/// Live shape captured 29/09/2026 (HTTP 200, Pro plan, 11.58% used):
///
/// ```json
/// { "currentPeriodStart": "2026-09-24T23:14:29.359Z",
///   "nextResetTimestampUtc": "2026-10-01T23:14:29.359Z",
///   "usagePercent": 11.578285,
///   "hasAvailableUsage": true,
///   "hasNonZeroIncludedLimit": true,
///   "grokPlanLabel": "Grok Bot Plan",
///   "cursorPlanName": "Pro",
///   "billingBrand": "SAND_BILLING_BRAND_CURSOR" }
/// ```
///
/// Facts this mapping depends on, all observed rather than assumed:
/// - `usagePercent` is USED percent (grows as the week is consumed), unlike
///   the Antigravity buckets which report remaining fraction. The account's
///   own UI renders it as the weekly bar, and the value rose across the week.
/// - The window is weekly by construction: the server's own method name is
///   `fetchSandWeeklyUsage` and the reset sits 7 days after the period start.
///   No duration math is needed, so the row is named directly.
/// - `nextResetTimestampUtc` is ISO 8601 UTC with fractional seconds.
/// - Spend, on-demand, upgrade CTAs, and trial fields are dropped for free by
///   plain `Decodable`. Spend dollars are a different product concern.
struct GrokUsageResponse: Decodable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let hasAvailableUsage: Bool?
    let hasNonZeroIncludedLimit: Bool?
    let usesPooledEnterpriseAllowance: Bool?
    let grokPlanLabel: String?
    let cursorPlanName: String?

    /// False when nothing in the payload is recognizable at all. This is the
    /// difference between "the weekly window has no metered percent" (a real
    /// answer, an honest empty list) and "the endpoint changed under us"
    /// (a failure to report honestly).
    var hasRecognizedPayload: Bool {
        currentPeriodStart != nil
            || nextResetTimestampUtc != nil
            || usagePercent != nil
    }

    /// Emits the single weekly row. A recognized payload without a usable
    /// percent produces no row rather than a zero: same rule as the
    /// Antigravity mapper for buckets without a metered limit.
    func toUsageLimits(now: Date = Date()) -> [UsageLimit] {
        guard let percent = usagePercent,
              percent.isFinite, percent >= 0,
              usesPooledEnterpriseAllowance != true
        else { return [] }
        let limit = UsageLimit(
            name: "Weekly",
            usedFraction: UsageWindow(
                usedPercent: percent,
                windowSeconds: nil,
                resetAfterSeconds: nil,
                resetAtEpochSeconds: nil
            ).usedFraction,
            resetsAt: AntigravityQuotaSummary.parseReset(nextResetTimestampUtc)
        )
        return UsageLimit.uniqued([limit])
    }
}
