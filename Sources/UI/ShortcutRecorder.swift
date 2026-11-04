import SwiftUI
import AppKit
import ChatGPTUsageCore

/// A "click, then press the keys" shortcut field. While recording it swallows
/// key presses inside this app only; Escape cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: GlobalShortcut?
    @State private var recording = false
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(label)
                    .frame(minWidth: 130)
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel("Panel shortcut: \(shortcut?.displayString ?? "none")")

            if shortcut != nil && !recording {
                Button("Clear") { shortcut = nil }
                    .controlSize(.small)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if recording { return "Press shortcut…" }
        return shortcut?.displayString ?? "Click to record"
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        hint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= GlobalShortcut.command }
        if flags.contains(.shift) { mods |= GlobalShortcut.shift }
        if flags.contains(.option) { mods |= GlobalShortcut.option }
        if flags.contains(.control) { mods |= GlobalShortcut.control }

        if event.keyCode == 53 && mods == 0 { stopRecording(); return }          // Escape
        if (event.keyCode == 51 || event.keyCode == 117) && mods == 0 {          // Delete
            shortcut = nil
            stopRecording()
            return
        }
        let candidate = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
        guard candidate.isValid else {
            hint = "Use ⌘, ⌥ or ⌃ with a key"
            return
        }
        shortcut = candidate
        stopRecording()
    }
}
