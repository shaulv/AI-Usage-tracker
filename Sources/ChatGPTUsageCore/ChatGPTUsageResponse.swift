import Foundation

/// Decodable mirror of `GET https://chatgpt.com/backend-api/wham/usage`.
///
/// Only the keys this app needs are declared; `credits`, `spend_control`,
/// `promo`, `rate_limit_reset_credits` and `plan_type` peers are dropped for
/// free by plain `Decodable`. That is deliberate: spend and credits are a
/// different product concern, and decoding them would be code that has to be
/// maintained for a feature that does not exist.
struct ChatGPTUsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimit?
    let codeReviewRateLimit: RateLimit?
    let additionalRateLimits: [NamedRateLimit]?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    /// False when nothing in the payload is recognizable at all. This is the
    /// difference between "the account has no limits" (a legitimate answer)
    /// and "the endpoint changed under us" (a failure to report honestly).
    var hasRecognizedPayload: Bool {
        planType != nil
            || rateLimit != nil
            || codeReviewRateLimit != nil
            || !(additionalRateLimits ?? []).isEmpty
    }

    struct RateLimit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        /// Stable order: primary then secondary, skipping absent windows.
        /// Never invent a window the payload did not contain.
        var presentWindows: [Window] {
            [primaryWindow, secondaryWindow].compactMap { $0 }
        }
    }

    struct NamedRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }

        var asUsageWindow: UsageWindow {
            UsageWindow(
                usedPercent: usedPercent,
                windowSeconds: limitWindowSeconds,
                resetAfterSeconds: resetAfterSeconds,
                resetAtEpochSeconds: resetAt
            )
        }
    }

    /// Emission order is stable and intentional: the account's own windows
    /// first, then code review, then every named per-model limit in server
    /// order. Nothing the server sends is silently dropped, which is what lets
    /// the app survive the next model OpenAI adds without a code change.
    ///
    /// `now` is a parameter so the `reset_after_seconds` fallback path is
    /// testable without waiting on a clock.
    func toUsageLimits(now: Date = Date()) -> [UsageLimit] {
        var limits: [UsageLimit] = []

        func append(_ rateLimit: RateLimit?, prefix: String?) {
            guard let rateLimit else { return }
            for (index, window) in rateLimit.presentWindows.enumerated() {
                let fallback = prefix ?? (index == 0 ? "Primary limit" : "Secondary limit")
                limits.append(
                    UsageLimit(
                        name: WindowNamer.name(forWindowSeconds: window.limitWindowSeconds, fallback: fallback),
                        usedFraction: window.asUsageWindow.usedFraction,
                        resetsAt: window.asUsageWindow.resolvesResetAt(now: now)
                    )
                )
            }
        }

        append(rateLimit, prefix: nil)
        append(codeReviewRateLimit, prefix: "Code review")

        for entry in additionalRateLimits ?? [] {
            let rawName = (entry.limitName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if !rawName.isEmpty {
                name = rawName
            } else {
                let humanized = WindowNamer.humanize(entry.meteredFeature ?? "")
                name = humanized.isEmpty ? "Additional limit" : humanized
            }
            if let rateLimit = entry.rateLimit {
                for (index, window) in rateLimit.presentWindows.enumerated() {
                    let suffix = rateLimit.presentWindows.count > 1 ? " (\(index + 1))" : ""
                    limits.append(
                        UsageLimit(
                            name: name + suffix,
                            usedFraction: window.asUsageWindow.usedFraction,
                            resetsAt: window.asUsageWindow.resolvesResetAt(now: now)
                        )
                    )
                }
            } else {
                // A named entry with no rate_limit object is still a fact the
                // server told us. Surface it at zero rather than dropping it.
                limits.append(UsageLimit(name: name, usedFraction: 0, resetsAt: nil))
            }
        }

        // Names are the row identity in the panel, so duplicates must not leave
        // this function: two windows of the same duration are a legitimate
        // payload, not an error.
        return UsageLimit.uniqued(limits)
    }
}
