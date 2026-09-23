import Foundation

/// "in 2h 14m", "in 47m", "now", "no reset time".
///
/// Relative rather than absolute because the question the menu bar answers is
/// "how long do I have", not "what time is it in UTC".
enum RelativeTime {
    static func string(from now: Date, to date: Date?) -> String {
        guard let date else { return "no reset time" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "now" }

        let minutes = Int(interval / 60)
        if minutes < 1 { return "in under a minute" }
        if minutes < 60 { return "in \(minutes)m" }

        let hours = minutes / 60
        let leftover = minutes % 60
        if hours < 24 {
            return leftover == 0 ? "in \(hours)h" : "in \(hours)h \(leftover)m"
        }

        let days = hours / 24
        let leftoverHours = hours % 24
        return leftoverHours == 0 ? "in \(days)d" : "in \(days)d \(leftoverHours)h"
    }
}
