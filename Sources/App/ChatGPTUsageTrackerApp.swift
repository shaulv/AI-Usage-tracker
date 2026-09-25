import SwiftUI
import ChatGPTUsageCore

/// The SwiftUI entry point. All real work happens in `AppDelegate`: the
/// status item, the floating panel, and the right-click menu are AppKit,
/// because the shell must support drag, resize, and a settings menu that
/// MenuBarExtra cannot provide.
///
/// The `Settings` scene is **not** decorative: macOS turns it into a real
/// `Settings...` app-menu item bound to Cmd-, and an `EmptyView` there makes
/// AppKit lay out an NSHostingView with no intrinsic content size, which
/// crashes inside `updateConstraintsIfNeeded`. It must always hold the real
/// thresholds UI.
@main
struct ChatGPTUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                notificationEngine: appDelegate.notificationEngine
            )
        }
    }
}

