import Foundation
import UserNotifications
import ChatGPTUsageCore

/// Protocol abstracting UNUserNotificationCenter for testability and isolation.
protocol NotificationClient: AnyObject {
    func requestAuthorization() async -> Bool
    func schedule(identifier: String, title: String, subtitle: String?, body: String, sound: Bool) async throws
}

/// Live implementation backed by macOS UserNotifications.framework.
final class LiveNotificationClient: NotificationClient {
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func schedule(
        identifier: String,
        title: String,
        subtitle: String?,
        body: String,
        sound: Bool
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        if sound {
            content.sound = .default
        }

        // Deliver immediately
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Dispatches macOS native alerts when AI quota limits cross into warning or critical status.
@MainActor
final class UsageNotificationEngine {
    private let settings: AppSettings
    private let client: NotificationClient
    private var statusTracker = UsageStatusTracker()

    init(settings: AppSettings, client: NotificationClient = LiveNotificationClient()) {
        self.settings = settings
        self.client = client
    }

    /// Evaluates fresh limits from a provider and posts alerts for any new warning/critical transitions.
    func process(providerId: String, providerDisplayName: String, limits: [UsageLimit]) {
        guard settings.notificationsEnabled else { return }

        let transitions = statusTracker.evaluate(
            providerId: providerId,
            limits: limits,
            config: settings.thresholdConfig
        )

        for event in transitions {
            let shouldAlert: Bool
            let titlePrefix: String
            let bodySuffix: String

            switch event.newLevel {
            case .warning:
                shouldAlert = settings.notifyOnWarning
                titlePrefix = "⚠️ AI Usage Warning"
                bodySuffix = "Usage is running low."
            case .critical:
                shouldAlert = settings.notifyOnCritical
                titlePrefix = "🚨 AI Usage Critical Alert"
                bodySuffix = "Usage is very low! Quota nearly exhausted."
            case .ok:
                shouldAlert = false
                titlePrefix = ""
                bodySuffix = ""
            }

            guard shouldAlert else { continue }

            let title = "\(titlePrefix): \(providerDisplayName)"
            let subtitle = "\(event.limitName) — \(event.remainingPercent)% left"
            let resetDesc = RelativeTime.string(from: Date(), to: event.resetsAt)
            let body = "\(bodySuffix) Resets \(resetDesc)."
            let identifier = "\(event.providerId)-\(event.limitName)-\(event.newLevel.rawValue)-\(Date().timeIntervalSince1970)"

            let sound = settings.notificationSound
            Task { [client] in
                try? await client.schedule(
                    identifier: identifier,
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    sound: sound
                )
            }
        }
    }

    /// Sends an instant sample alert to test permissions and sound.
    func sendTestNotification() {
        let title = "AI Usage tracker — Test Notification"
        let subtitle = "Notifications are working!"
        let body = "You will receive alerts here when usage drops below your warning or critical thresholds."
        let sound = settings.notificationSound
        let identifier = "test-notification-\(Date().timeIntervalSince1970)"

        Task { [client] in
            _ = await client.requestAuthorization()
            try? await client.schedule(
                identifier: identifier,
                title: title,
                subtitle: subtitle,
                body: body,
                sound: sound
            )
        }
    }
}
