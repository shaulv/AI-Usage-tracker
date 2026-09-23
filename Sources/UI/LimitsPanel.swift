import SwiftUI
import ChatGPTUsageCore
import AppKit
import ServiceManagement

/// The whole UI. Fixed 320 pt wide, 8 pt spacing grid, no layout shift when a
/// state changes: every state occupies the same slot and only its text changes.
struct LimitsPanel: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.colorScheme) private var colorScheme

    private let panelWidth: CGFloat = 320
    private let gap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: panelWidth)
    }

    private var header: some View {
        HStack(spacing: gap) {
            Text("ChatGPT")
                .font(.headline)
            Spacer()
            Button {
                Task { @MainActor in
                    await store.refresh()
                }
            } label: {
                if case .refreshing = store.state {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .failed(let message):
            failedView(message)
        default:
            if let limits = store.limits, !limits.isEmpty {
                limitsList(limits)
            } else {
                emptyView
            }
        }
    }

    /// The rows ARE the selection control. One control, one home: there is no
    /// separate picker that duplicates this choice, and clicking a row is also
    /// its keyboard action, so the affordance is not mouse-only.
    private func limitsList(_ limits: [UsageLimit]) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            Text("Menu bar shows the selected limit")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(limits) { limit in
                let isSelected = limit.name == store.selectedLimit?.name
                Button {
                    store.selectedLimitName = limit.name
                } label: {
                    LimitRow(limit: limit, isSelected: isSelected, gap: gap)
                }
                .buttonStyle(PanelRowButtonStyle())
                .help(isSelected ? "Shown in the menu bar" : "Show this limit in the menu bar")
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            Text(message)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("No usage is shown until a fetch succeeds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: gap) {
            Text("No usage limits available")
                .font(.body)
            Text("This account reports no metered windows. Everyday text chat is not metered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: gap) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            LaunchAtLoginToggle()
            Button("Quit", action: quit)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Quit ChatGPT Usage")
        }
        .frame(height: 20)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// A visible last-updated line, so a silently broken endpoint cannot hide
    /// behind a stale number.
    private var statusText: String {
        switch store.state {
        case .idle:
            return "not fetched yet"
        case .refreshing:
            return "updating…"
        case .ok:
            return "updated \(store.lastUpdatedText)"
        case .failed:
            return "failed, last good \(store.lastUpdatedText)"
        }
    }
}

/// One limit. Fixed element order in every row: dot, name, percent, reset.
/// The percent is the loudest element because it is the thing being scanned.
private struct LimitRow: View {
    let limit: UsageLimit
    let isSelected: Bool
    let gap: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: gap) {
            Circle()
                .fill(ThresholdColors.color(
                    for: ThresholdColors.Level(usedFraction: limit.usedFraction),
                    scheme: colorScheme
                ))
                .frame(width: 8, height: 8)

            Text(limit.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: gap)

            Text("\(limit.usedPercentRounded)%")
                .font(.body.monospacedDigit().weight(.semibold))

            Text(RelativeTime.string(from: Date(), to: limit.resetsAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// Keeps the row's own colors instead of the tinted look AppKit gives button
/// labels, and confines the press state inside the row's frame.
private struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Launch at login, via the modern API. Registering can fail without a
/// developer-signed build, so the toggle degrades to a message instead of
/// silently doing nothing.
private struct LaunchAtLoginToggle: View {
    @State private var isOn: Bool = SMAppService.mainApp.status == .enabled
    @State private var failureMessage: String?

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("Start at login")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
        .help(failureMessage ?? "Start this app when you log in")
        .onChange(of: isOn) { _, newValue in
            apply(newValue)
        }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failureMessage = nil
        } catch {
            failureMessage = "Could not change launch at login: \(error.localizedDescription)"
            isOn = SMAppService.mainApp.status == .enabled
        }
    }
}
