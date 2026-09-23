import SwiftUI
import ChatGPTUsageCore

@main
struct ChatGPTUsageTrackerApp: App {
    // @StateObject (not a plain let): the menu-bar label reads
    // store.menuBarLabel, so the label only re-renders when SwiftUI observes
    // the store. The refresh is kicked off from a .task modifier, never from
    // init — touching a StateObject's wrapped value in init spawns a
    // throwaway instance and the fetch never reaches the panel.
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            LimitsPanel()
                .environmentObject(store)
        } label: {
            // A dedicated observing view (not an inline Text): the label only
            // re-renders when the view itself observes the store, and the
            // label is always mounted, so its .task fires at launch — the
            // first fetch happens without opening the panel.
            MenuBarLabel(store: store)
                .task {
                    store.start()
                    await store.refresh()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar label. A separate view so it observes the store itself: an
/// inline `Text(store.menuBarLabel)` in the scene closure is evaluated once
/// and never updates, which is how the bar can sit on "--%" forever while
/// the panel shows real numbers.
private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Text(store.menuBarLabel)
            .monospacedDigit()
    }
}
