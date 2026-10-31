import Foundation

/// The claude.ai usage payload, captured live against a real account before any
/// Swift was written (HTTP 200, Chrome UA, session cookies from Claude Desktop).
///
/// Shape notes that the mapping depends on:
/// - Keys are present even when their value is `null` (a window with no active
///   usage reports null, not a missing key). "Recognized" therefore means "one
///   of these keys exists", not "a bucket is non-null".
/// - `utilization` is a percent in 0...100 (same unit as ChatGPT's
///   `used_percent`), clamped downstream exactly like ChatGPT's values.
/// - `resets_at` is RFC 3339 UTC ("2026-04-08T18:59:59Z"), NOT epoch seconds.
///   ChatGPT sends epoch seconds; the two parsers are deliberately different.
/// - `seven_day_opus` / `seven_day_sonnet` appear only when the account has
///   per-model weekly buckets. `extra_usage` carries credits, not a reset.
public struct ClaudeUsageResponse: Decodable {
    public struct Bucket: Decodable {
        public let utilization: Double?
        public let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: .resetsAt) {
                resetsAt = stringValue
            } else if let numValue = try? container.decodeIfPresent(Double.self, forKey: .resetsAt) {
                resetsAt = String(numValue)
            } else {
                resetsAt = nil
            }
        }

        public init(utilization: Double?, resetsAt: String?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    public struct ExtraUsage: Decodable {
        public let isEnabled: Bool?
        public let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case utilization
        }
    }

    public let fiveHour: Bucket?
    public let sevenDay: Bucket?
    public let sevenDayOpus: Bucket?
    public let sevenDaySonnet: Bucket?
    public let extraUsage: ExtraUsage?
    public let hasRecognizedPayload: Bool

    private enum Keys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        hasRecognizedPayload = container.contains(.fiveHour)
            || container.contains(.sevenDay)
            || container.contains(.sevenDayOpus)
            || container.contains(.sevenDaySonnet)
            || container.contains(.extraUsage)
            || container.contains(.limits)
        fiveHour = try container.decodeIfPresent(Bucket.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(Bucket.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(Bucket.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(Bucket.self, forKey: .sevenDaySonnet)
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
    }

    /// Maps every non-null bucket to a display row. An empty array is a real
    /// answer (free plan, nothing metered yet), never an error.
    /// `utilization` arrives as a percent (0...100) and `UsageLimit` wants a
    /// fraction (0...1), so the division and the clamp happen exactly here —
    /// one place, not scattered per-bucket.
    public func toUsageLimits(now: Date = Date()) -> [UsageLimit] {
        var limits: [UsageLimit] = []
        func fraction(_ percent: Double) -> Double {
            min(max(percent, 0), 100) / 100
        }

        // Known buckets carry their true duration, so naming flows through the
        // same duration-based namer ChatGPT uses — one naming brain, two APIs.
        if let bucket = fiveHour, let percent = bucket.utilization {
            limits.append(UsageLimit(
                name: WindowNamer.name(forWindowSeconds: 18_000, fallback: "Session"),
                usedFraction: fraction(percent),
                resetsAt: Self.parseReset(bucket.resetsAt)
            ))
        }
        if let bucket = sevenDay, let percent = bucket.utilization {
            limits.append(UsageLimit(
                name: WindowNamer.name(forWindowSeconds: 604_800, fallback: "Weekly"),
                usedFraction: fraction(percent),
                resetsAt: Self.parseReset(bucket.resetsAt)
            ))
        }
        if let bucket = sevenDayOpus, let percent = bucket.utilization {
            limits.append(UsageLimit(
                name: "Weekly (Opus)",
                usedFraction: fraction(percent),
                resetsAt: Self.parseReset(bucket.resetsAt)
            ))
        }
        if let bucket = sevenDaySonnet, let percent = bucket.utilization {
            limits.append(UsageLimit(
                name: "Weekly (Sonnet)",
                usedFraction: fraction(percent),
                resetsAt: Self.parseReset(bucket.resetsAt)
            ))
        }
        if let extra = extraUsage, extra.isEnabled == true, let percent = extra.utilization {
            limits.append(UsageLimit(
                name: "Extra usage",
                usedFraction: fraction(percent),
                resetsAt: nil
            ))
        }
        // Same invariant as the ChatGPT mapper: names are row identity, so this
        // is the one place duplicates are resolved.
        return UsageLimit.uniqued(limits)
    }

    /// RFC 3339 / ISO 8601 UTC parser supporting both fractional seconds
    /// (.528743+00:00 / .000Z) and standard format (18:59:59Z), plus epoch timestamps.
    public static func parseReset(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }

        // 1. Anthropic live format: ISO 8601 with fractional seconds and offset/Z
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: text) {
            return date
        }

        // 2. Standard RFC 3339 without fractional seconds
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        if let date = standardFormatter.date(from: text) {
            return date
        }

        // 3. Fallback: Unix epoch seconds or milliseconds
        if let epoch = Double(text), epoch > 1_000_000_000 {
            let seconds = epoch > 1_000_000_000_000 ? epoch / 1000.0 : epoch
            return Date(timeIntervalSince1970: seconds)
        }

        return nil
    }
}

/// Builds `UsageLimit` rows from raw response bytes, enforcing the same three
/// rules as the ChatGPT side: decode failure is a fetch failure (an HTML
/// interstitial served with a 200 is not an empty account), an unrecognized
/// payload is a fetch failure, and a recognized payload with no active buckets
/// is a real empty list.
public enum ClaudeUsageMapper {
    public static func limits(from data: Data) throws -> [UsageLimit] {
        let payload: ClaudeUsageResponse
        do {
            payload = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Claude usage service"
            )
        }
        guard payload.hasRecognizedPayload else {
            throw UsageProviderError.fetchFailed(
                "Unexpected response from Claude usage service"
            )
        }
        return payload.toUsageLimits()
    }
}
