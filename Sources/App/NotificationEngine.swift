import Foundation
import UserNotifications
import ChatGPTUsageCore

/// Protocol abstracting UNUserNotificationCenter for testability and isolation.
protocol NotificationClient: AnyObject {
    func requestAuthorization() async -> Bool
    func schedule(identifier: String, title: String, subtitle: String?, body: String, sound: Bool) async throws
    func authorizationStatus() async -> UNAuthorizationStatus
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

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
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
final class UsageNotificationEngine: ObservableObject {
    private let settings: AppSettings
    private let client: NotificationClient
    private var statusTracker = UsageStatusTracker()

    /// Human-readable authorization state, refreshed by `refreshAuthorizationStatus()`.
    /// The settings window renders this instead of silently guessing.
    @Published var authorizationState: String = "Checking…"
    /// Outcome of the last `Send Test Notification` tap. Non-nil means the user
    /// was shown a result - the old code discarded every error with `try?`.
    @Published var lastTestResult: String?
    /// True when notifications are blocked at the OS level, so the settings
    /// window can offer the System Settings deep link.
    @Published var notificationsBlocked: Bool = false
    /// True once the last test notification was confirmed handed to the system.
    @Published var lastTestSucceeded: Bool = false

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
    ///
    /// Every outcome is published. The previous version discarded both the
    /// authorization result (`_ = await`) and the scheduling error (`try?`),
    /// so a refusal by `usernotificationsd` produced total silence and the
    /// button looked broken. Now the settings window always says what happened.
    func sendTestNotification() {
        lastTestSucceeded = false
        lastTestResult = "Sending…"
        let title = "AI Usage tracker — Test Notification"
        let subtitle = "Notifications are working!"
        let body = "You will receive alerts here when usage drops below your warning or critical thresholds."
        let sound = settings.notificationSound
        let identifier = "test-notification-\(Date().timeIntervalSince1970)"

        Task { [weak self] in
            guard let self else { return }

            let granted = await self.client.requestAuthorization()
            guard granted else {
                await self.refreshAuthorizationState()
                self.lastTestSucceeded = false
                self.lastTestResult = "Blocked — macOS refused notification permission for "
                    + "AI Usage tracker. This is refused before the permission prompt "
                    + "when the app bundle has no valid code signature, so System "
                    + "Settings has no entry to toggle."
                return
            }

            do {
                try await self.client.schedule(
                    identifier: identifier,
                    title: title,
                    subtitle: subtitle,
                    body: body,
                    sound: sound
                )
                self.lastTestSucceeded = true
                self.lastTestResult = "Delivered — the test notification was handed to Notification Center."
            } catch {
                self.lastTestSucceeded = false
                let nsError = error as NSError
                self.lastTestResult = "Failed — \(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
            }

            await self.refreshAuthorizationState()
        }
    }

    /// Reads the live OS authorization state. Called on appear and after every
    /// test, so the window never shows a stale answer.
    func refreshAuthorizationStatus() {
        Task { [weak self] in
            await self?.refreshAuthorizationState()
        }
    }

    private func refreshAuthorizationState() async {
        switch await client.authorizationStatus() {
        case .authorized:        authorizationState = "Authorized"
        case .provisional:       authorizationState = "Authorized (quiet delivery)"
        case .ephemeral:         authorizationState = "Authorized (temporary)"
        case .denied:            authorizationState = "Blocked"
        case .notDetermined:     authorizationState = "Not requested yet"
        @unknown default:        authorizationState = "Unknown"
        }
        notificationsBlocked = (authorizationState == "Blocked")
    }
}
