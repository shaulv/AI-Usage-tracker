import Foundation
import ChatGPTUsageCore

/// Every user-facing preference, one UserDefaults key each, so the right-click
/// menu and the panel share one source of truth and nothing is decided in a
/// view. Written on change, read once at launch.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Whether the floating panel was visible when the app last ran: the panel
    /// reopens in the state the user left it in.
    @Published var panelEnabled: Bool {
        didSet { defaults.set(panelEnabled, forKey: "panelEnabled") }
    }
    /// Provider toggles. Disabling a provider stops its timer and hides its
    /// section; it never deletes data or changes the other provider.
    @Published var chatGPTEnabled: Bool {
        didSet { defaults.set(chatGPTEnabled, forKey: "chatGPTEnabled") }
    }
    @Published var claudeEnabled: Bool {
        didSet { defaults.set(claudeEnabled, forKey: "claudeEnabled") }
    }
    @Published var antigravityEnabled: Bool {
        didSet { defaults.set(antigravityEnabled, forKey: "antigravityEnabled") }
    }
    @Published var cursorEnabled: Bool {
        didSet { defaults.set(cursorEnabled, forKey: "cursorEnabled") }
    }
    @Published var grokEnabled: Bool {
        didSet { defaults.set(grokEnabled, forKey: "grokEnabled") }
    }
    /// What the menu-bar status item shows: bare session percent, or the
    /// `S..% W..%` pair. A fresh install starts on the pair: a weekly window the
    /// user cannot see is the more expensive blind spot of the two.
    @Published var headerStyle: HeaderStyle {
        didSet { defaults.set(headerStyle.rawValue, forKey: "headerStyle") }
    }
    /// Which AI model/provider appears in the menu bar header: specific provider or automatic.
    @Published var headerProvider: HeaderProvider {
        didSet { defaults.set(headerProvider.rawValue, forKey: "headerProvider") }
    }
    /// Whether the menu bar and the panel report how much is LEFT (100 - used)
    /// rather than how much is used. Defaults on: the remaining count is the one
    /// that drives behavior, so it is the more useful glance.
    @Published var showRemaining: Bool {
        didSet { defaults.set(showRemaining, forKey: "showRemaining") }
    }

    /// Global shortcut that shows the panel when hidden and hides it when
    /// shown. Nil until the user records one, so it can never collide with a
    /// shortcut they already rely on.
    @Published var toggleShortcut: GlobalShortcut? {
        didSet {
            if let toggleShortcut {
                defaults.set(toggleShortcut.storageValue, forKey: "toggleShortcut")
            } else {
                defaults.removeObject(forKey: "toggleShortcut")
            }
        }
    }
    /// Set by the app when macOS refused the recorded shortcut (already taken).
    /// Not persisted.
    @Published var toggleShortcutUnavailable = false

    // MARK: - Thresholds & Notifications

    /// Warning threshold (orange status): triggers when quota remaining % is at or below this value.
    @Published var warningRemainingThreshold: Int {
        didSet {
            let clamped = max(criticalRemainingThreshold + 1, min(warningRemainingThreshold, 99))
            if clamped != warningRemainingThreshold { warningRemainingThreshold = clamped }
            defaults.set(warningRemainingThreshold, forKey: "warningRemainingThreshold")
        }
    }
    /// Critical threshold (red alert): triggers when quota remaining % is at or below this value.
    @Published var criticalRemainingThreshold: Int {
        didSet {
            let clamped = max(1, min(criticalRemainingThreshold, warningRemainingThreshold - 1))
            if clamped != criticalRemainingThreshold { criticalRemainingThreshold = clamped }
            defaults.set(criticalRemainingThreshold, forKey: "criticalRemainingThreshold")
        }
    }
    /// Global toggle for native macOS notifications.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    /// Whether to send an alert when entering Warning status (orange).
    @Published var notifyOnWarning: Bool {
        didSet { defaults.set(notifyOnWarning, forKey: "notifyOnWarning") }
    }
    /// Whether to send an alert when entering Critical status (red alert).
    @Published var notifyOnCritical: Bool {
        didSet { defaults.set(notifyOnCritical, forKey: "notifyOnCritical") }
    }
    /// Whether notifications play the default alert sound.
    @Published var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: "notificationSound") }
    }

    /// Computed threshold configuration reflecting current settings.
    var thresholdConfig: ThresholdConfiguration {
        ThresholdConfiguration(
            warningRemainingPercent: warningRemainingThreshold,
            criticalRemainingPercent: criticalRemainingThreshold
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.panelEnabled = defaults.object(forKey: "panelEnabled") as? Bool ?? true
        self.chatGPTEnabled = defaults.object(forKey: "chatGPTEnabled") as? Bool ?? true
        self.claudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        self.antigravityEnabled = defaults.object(forKey: "antigravityEnabled") as? Bool ?? true
        self.cursorEnabled = defaults.object(forKey: "cursorEnabled") as? Bool ?? true
        self.grokEnabled = defaults.object(forKey: "grokEnabled") as? Bool ?? true
        self.toggleShortcut = defaults.string(forKey: "toggleShortcut")
            .flatMap { GlobalShortcut(storageValue: $0) }
        let rawStyle = defaults.string(forKey: "headerStyle") ?? ""
        self.headerStyle = HeaderStyle(rawValue: rawStyle) ?? .sessionWeekly
        let rawProvider = defaults.string(forKey: "headerProvider") ?? ""
        self.headerProvider = HeaderProvider(rawValue: rawProvider) ?? .auto
        self.showRemaining = defaults.object(forKey: "showRemaining") as? Bool ?? true

        let savedWarn = defaults.object(forKey: "warningRemainingThreshold") as? Int
            ?? ThresholdConfiguration.defaultWarningRemainingPercent
        let savedCrit = defaults.object(forKey: "criticalRemainingThreshold") as? Int
            ?? ThresholdConfiguration.defaultCriticalRemainingPercent
        let validCrit = max(1, min(savedCrit, 98))
        let validWarn = max(validCrit + 1, min(savedWarn, 99))
        self.criticalRemainingThreshold = validCrit
        self.warningRemainingThreshold = validWarn

        self.notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.notifyOnWarning = defaults.object(forKey: "notifyOnWarning") as? Bool ?? true
        self.notifyOnCritical = defaults.object(forKey: "notifyOnCritical") as? Bool ?? true
        self.notificationSound = defaults.object(forKey: "notificationSound") as? Bool ?? true
    }
}

