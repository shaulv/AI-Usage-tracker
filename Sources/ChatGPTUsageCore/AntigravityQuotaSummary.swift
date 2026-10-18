import Foundation

/// Decodable mirror of the language server's `RetrieveUserQuotaSummary`
/// response, captured live on 24/09/2026 (`HTTP 200` over loopback HTTPS):
///
/// ```json
/// { "response": { "groups": [
///     { "displayName": "Gemini Models",
///       "buckets": [
///         { "bucketId": "gemini-weekly", "window": "weekly",
///           "remainingFraction": 0.8074015, "resetTime": "2026-09-30T13:51:30Z" },
///         { "bucketId": "gemini-5h", "window": "5h",
///           "remainingFraction": 0.9050501, "resetTime": "2026-09-24T23:08:04Z" } ] },
///     { "displayName": "Claude and GPT models",
///       "buckets": [ { "bucketId": "3p-weekly", ... }, { "bucketId": "3p-5h", ... } ] } ] } }
/// ```
///
/// Facts this mapping depends on, all observed rather than assumed:
/// - `remainingFraction` is REMAINING, not used: the group reported `0` for
///   `3p-5h` together with the text "You have hit your 5-hour limit".
/// - Each bucket states its own `window` (`"5h"` or `"weekly"`), so the window
///   is read, never guessed from a reset delta.
/// - `resetTime` is ISO 8601 UTC. A bucket can legitimately omit
///   `remainingFraction` (the per-model listing does exactly that for models
///   with no metered limit), and such a bucket is not a row.
/// - Groups are named ("Gemini Models", "Claude and GPT models",
///   "Gemini 4 Argon") and their bucket ids are prefixed (`gemini-*`,
///   `3p-*`, `gemini-argon-*`), so pool identity has two independent signals.
/// - Argon is a separate weekly-only pool. Its bucket ids still start with
///   `gemini-` (for example `gemini-argon-wtu-weekly`), so Argon must be
///   classified before the Gemini prefix check or it overwrites Gemini Weekly.
public struct AntigravityQuotaSummary: Decodable {
    public struct Bucket: Decodable {
        public let bucketId: String?
        public let displayName: String?
        public let window: String?
        public let remainingFraction: Double?
        public let resetTime: String?

        enum CodingKeys: String, CodingKey {
            case bucketId
            case displayName
            case window
            case remainingFraction
            case resetTime
        }
    }

    public struct Group: Decodable {
        public let displayName: String?
        public let description: String?
        public let buckets: [Bucket]?
    }

    public struct Body: Decodable {
        public let groups: [Group]?
    }

    public let response: Body?

    public var hasRecognizedPayload: Bool {
        !(response?.groups ?? []).isEmpty
    }
}

/// Maps the summary's groups and buckets to the rows the panel and the menu
/// bar look for: `Gemini Session`, `Gemini Weekly`, `Third-party Session`,
/// `Third-party Weekly`, and when present `Argon Weekly`.
///
/// Shared Gemini and third-party pools each expose session + weekly windows.
/// Argon is a separate weekly-only pool (no Argon Session row is invented). A
/// pool or window the server did not report produces no row, because an absent
/// window must never render as a zero.
public extension AntigravityQuotaSummary {
    enum Pool { case gemini, thirdParty, argon }
    enum Window { case session, weekly }

    func toUsageLimits(now: Date = Date()) -> [UsageLimit] {
        var worst: [Row: (fraction: Double, reset: Date?)] = [:]

        for group in response?.groups ?? [] {
            for bucket in group.buckets ?? [] {
                guard let remaining = bucket.remainingFraction else { continue }
                let row = Row(
                    pool: Self.pool(for: bucket, group: group),
                    window: Self.window(for: bucket, now: now)
                )
                let used = min(max(1.0 - remaining, 0), 1)
                let reset = Self.parseReset(bucket.resetTime)
                if let current = worst[row], current.fraction >= used { continue }
                worst[row] = (used, reset)
            }
        }

        var limits: [UsageLimit] = []
        func append(_ pool: Pool, _ window: Window, _ name: String) {
            guard let row = worst[Row(pool: pool, window: window)] else { return }
            limits.append(UsageLimit(name: name, usedFraction: row.fraction, resetsAt: row.reset))
        }
        append(.gemini, .session, "Gemini Session")
        append(.gemini, .weekly, "Gemini Weekly")
        append(.thirdParty, .session, "Third-party Session")
        append(.thirdParty, .weekly, "Third-party Weekly")
        append(.argon, .weekly, "Argon Weekly")

        // Same invariant as the ChatGPT and Claude mappers: names are row
        // identity, so duplicates are resolved in exactly one place.
        return UsageLimit.uniqued(limits)
    }

    /// Pool identity. Argon is checked first because its bucket ids still start
    /// with `gemini-` (`gemini-argon-wtu-weekly`); classifying Gemini by that
    /// prefix alone would merge Argon into Gemini Weekly. Then Gemini
    /// (`gemini-` / group name), then third-party (`3p-`). Defaulting to
    /// third-party is deliberate: only an explicit Gemini signal earns Gemini
    /// rows.
    static func pool(for bucket: Bucket, group: Group) -> Pool {
        let bucketId = (bucket.bucketId ?? "").lowercased()
        let groupName = (group.displayName ?? "").lowercased()
        if bucketId.contains("argon") || groupName.contains("argon") {
            return .argon
        }
        if bucketId.hasPrefix("gemini") || groupName.contains("gemini") {
            return .gemini
        }
        if bucketId.hasPrefix("3p") { return .thirdParty }
        return .thirdParty
    }

    /// Window from the bucket's own `window` field. The reset-delta fallback
    /// exists only for a payload that omits the field: over 24 hours out is a
    /// weekly window, anything sooner or unknown is a session window, because
    /// an unknown reset must never invent a weekly row.
    static func window(for bucket: Bucket, now: Date) -> Window {
        switch (bucket.window ?? "").lowercased() {
        case "weekly", "week": return .weekly
        case "5h", "5-hour", "5hour", "session", "daily": return .session
        default: break
        }
        guard let reset = parseReset(bucket.resetTime) else { return .session }
        return reset.timeIntervalSince(now) > 24 * 3600 ? .weekly : .session
    }

    /// ISO 8601 UTC, fixed format so a locale cannot reinterpret the timestamp.
    /// Both fraction-bearing and plain variants are accepted because the server
    /// has sent both shapes.
    static func parseReset(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    struct Row: Hashable {
        let pool: Pool
        let window: Window
    }
}

/// Builds rows from raw response bytes, enforcing the same three rules as the
/// ChatGPT and Claude sides: decode failure is a fetch failure, an unrecognized
/// payload is a fetch failure, and a recognized payload with no usable buckets
/// is a real empty list.
public enum AntigravityUsageMapper {
    public static func limits(from data: Data) throws -> [UsageLimit] {
        let payload: AntigravityQuotaSummary
        do {
            payload = try JSONDecoder().decode(AntigravityQuotaSummary.self, from: data)
        } catch {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Antigravity usage service"
            )
        }
        guard payload.hasRecognizedPayload else {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Antigravity usage service"
            )
        }
        return payload.toUsageLimits()
    }
}
