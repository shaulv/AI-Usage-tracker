import SwiftUI
import ChatGPTUsageCore

/// The SwiftUI entry point. All real work happens in `AppDelegate`: the
/// status item, the floating panel, and the right-click menu are AppKit,
/// because the shell must support drag, resize, and a settings menu that
/// MenuBarExtra cannot provide. The Settings scene exists only so the App
/// struct has one scene to satisfy the framework; nothing opens it.
@main
struct ChatGPTUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

