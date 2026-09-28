import SwiftUI
import ChatGPTUsageCore
import AppKit

/// The whole panel. Responsive on width:
///  - wide: one condensed row — the usage chips left, the refresh button right.
///  - narrow: the pre-redesign layout, each limit on its own line.
// / There is no title text and no quit button in the panel. Quit, start-at-login,
/// and the on/off toggles live in the right-click menu, so the panel is only ever
/// as tall as it needs to be. Every state occupies the same slot and only its
/// text changes, so no state change can shift the layout under the cursor.
struct LimitsPanel: View {
    /// ChatGPT keeps the environment slot it has always used, unchanged.
    ///
    /// Claude and Gemini are injected as ordinary distinct properties on
    /// purpose: SwiftUI keys its environment by TYPE, not by property name, so
    /// three `UsageStore`s written into one environment collapse to a single
    /// instance. Measured on 24/09/2026 before this fix: the view saw
    /// `ObjectIdentifier(0xac5114b00)` for all three properties, which rendered
    /// ChatGPT's numbers inside the Claude and Gemini sections. Two of the
    /// three sections have to arrive some other way for the panel to tell them
    /// apart, and this is the cheapest correct way: no container type, so no
    /// manual `objectWillChange` forwarding to get wrong.
    @EnvironmentObject private var chatGPT: UsageStore
    @ObservedObject var claude: UsageStore
    @ObservedObject var antigravity: UsageStore
    @ObservedObject var cursor: UsageStore
    @ObservedObject var grok: UsageStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private let gap: CGFloat = 6
    /// Below this width the strip cannot hold chips comfortably: stack instead.
    private let stripBreakpoint: CGFloat = 560

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                usageArea(isStrip: geo.size.width >= stripBreakpoint)
                disabledProviderHint
                footer
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            #if DEBUG
            // Guard against reintroducing the collision described above:
            // distinct instances are the only thing keeping these three
            // sections honest, so a debug build fails loudly if that stops
            // being true.
            let identifiers = [
                ObjectIdentifier(chatGPT),
                ObjectIdentifier(claude),
                ObjectIdentifier(antigravity),
                ObjectIdentifier(cursor),
                ObjectIdentifier(grok),
            ]
            assert(
                Set(identifiers).count == identifiers.count,
                "LimitsPanel received the same UsageStore instance more than once - check store injection"
            )
            #endif
        }
    }

    // MARK: - Usage area (wide = single condensed row, narrow = stacked)

    /// Wide: `stripRows` + a spacer + the refresh button, all on one line —
    /// usages left, refresh right. Narrow: a top line with the refresh button
    /// on the right, then one line per limit (the pre-redesign layout). Empty
    /// and failed states share the wide line shape so the slot never jumps.
    @ViewBuilder
    private func usageArea(isStrip: Bool) -> some View {
        let rows = enabledStores.flatMap { providerRows($0) }
        if rows.isEmpty {
            HStack(spacing: gap) {
                emptyOrFailed
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                refreshButton
            }
            .frame(height: 20)
        } else if isStrip {
            HStack(spacing: gap) {
                stripRows(rows)
                Spacer()
                refreshButton
            }
        } else {
            VStack(alignment: .leading, spacing: gap) {
                stackedRows(rows)
                HStack { Spacer(); refreshButton }
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { @MainActor in
                if settings.chatGPTEnabled { await chatGPT.refresh() }
                if settings.claudeEnabled { await claude.refresh() }
                if settings.antigravityEnabled { await antigravity.refresh() }
                if settings.cursorEnabled { await cursor.refresh() }
                if settings.grokEnabled { await grok.refresh() }
            }
        } label: {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .help("Refresh now")
    }

    private var isRefreshing: Bool {
        if case .refreshing = chatGPT.state { return true }
        if case .refreshing = claude.state { return true }
        if case .refreshing = antigravity.state { return true }
        if case .refreshing = cursor.state { return true }
        if case .refreshing = grok.state { return true }
        return false
    }

    /// The percent this row shows: remaining (100 - used) when `showRemaining`
    /// is on, else used. One policy site for both row styles so they can never
    /// disagree.
    private func percent(for row: ProviderRow) -> Int {
        settings.showRemaining ? row.limit.remainingPercentRounded : row.limit.usedPercentRounded
    }

    // MARK: - Rows

    /// Strip layout: one line of compact chips, providers in order, a small
    /// provider tag only when both are on so a single provider stays clean.
    private func stripRows(_ rows: [ProviderRow]) -> some View {
        HStack(spacing: gap) {
            ForEach(rows) { row in
                rowChip(row, showProvider: enabledStores.count > 1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Stacked layout: the original card rows, one per limit, two providers
    /// under uppercase labels. A provider with nothing to show contributes its
    /// message instead — failure names the provider so the user knows which fix
    /// applies, and an honest empty says so rather than vanishing while its
    /// sibling lists rows.
    private func stackedRows(_ rows: [ProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(enabledStores, id: \.name) { provider in
                let own = rows.filter { $0.providerName == provider.name }
                if !own.isEmpty {
                    if enabledStores.count > 1 {
                        Text(provider.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    ForEach(own) { row in
                        selectButton(row) {
                            stackedRowView(row)
                        }
                    }
                } else if let message = providerMessage(provider) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What a provider with no rows says, in the same slot its rows would
    /// occupy. Nil when the provider is merely between fetches with data on
    /// the way (its rows will be back on the next publish).
    private func providerMessage(_ provider: (name: String, store: UsageStore)) -> String? {
        switch provider.store.state {
        case .failed(let message):
            return "\(provider.name): \(message)"
        case .refreshing where provider.store.limits?.isEmpty ?? true:
            return "\(provider.name): updating…"
        case .ok where provider.store.limits?.isEmpty ?? true:
            return "\(provider.name): no usage limits available"
        case .idle where provider.store.limits == nil:
            return "\(provider.name): not fetched yet"
        default:
            return nil
        }
    }

    /// A provider the user switched off gets one muted line. Without it "Claude
    /// is missing" and "Claude is off" look identical, and only the second one
    /// is a toggle away from being fixed. Both providers off is already
    /// summarized in the footer, so this deliberately stays a single line.
    @ViewBuilder
    private var disabledProviderHint: some View {
        if let off = disabledProviderName {
            Text("\(off) off")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Turn \(off) back on from the right-click menu")
        }
    }

    private var disabledProviderName: String? {
        let off = [
            settings.chatGPTEnabled ? nil : "ChatGPT",
            settings.claudeEnabled ? nil : "Claude",
            settings.antigravityEnabled ? nil : "Gemini",
            settings.cursorEnabled ? nil : "Cursor",
            settings.grokEnabled ? nil : "Grok",
        ].compactMap { $0 }
        return off.count == 1 ? off[0] : nil
    }

    /// A provider the user switched off contributes nothing: no rows, no
    /// status, no error. Its data is untouched, just not shown.
    private struct ProviderRow: Identifiable {
        let store: UsageStore
        let limit: UsageLimit
        let providerName: String
        let isSelected: Bool

        /// Unique per ROW, not per provider. Identity by provider alone was the
        /// defect: every row of a provider shared one SwiftUI identity, so
        /// SwiftUI reused a single view and its content and the second row
        /// rendered as a copy of the first ("Session (5h)" drawn twice, the
        /// weekly row never appearing).
        var id: String { "\(providerName)|\(limit.name)" }
    }

    private var enabledStores: [(name: String, store: UsageStore)] {
        var list: [(String, UsageStore)] = []
        if settings.chatGPTEnabled { list.append(("ChatGPT", chatGPT)) }
        if settings.claudeEnabled { list.append(("Claude", claude)) }
        if settings.antigravityEnabled { list.append(("Gemini", antigravity)) }
        if settings.cursorEnabled { list.append(("Cursor", cursor)) }
        if settings.grokEnabled { list.append(("Grok", grok)) }
        return list
    }

    private func providerRows(_ provider: (name: String, store: UsageStore)) -> [ProviderRow] {
        guard let limits = provider.store.limits, !limits.isEmpty else { return [] }
        return limits.map { limit in
            ProviderRow(
                store: provider.store,
                limit: limit,
                providerName: provider.name,
                isSelected: limit.name == provider.store.selectedLimit?.name
            )
        }
    }

    /// Single-click-to-promote row. Wraps each chip so clicking it makes that
    /// window the menu-bar value, with a stable identity per row.
    private func selectButton<Label: View>(_ row: ProviderRow, @ViewBuilder label: () -> Label) -> some View {
        Button {
            row.store.selectedLimitName = row.limit.name
        } label: {
            label()
        }
        .buttonStyle(PanelRowButtonStyle())
        .help(row.isSelected
            ? "Shown in the menu bar"
            : "Show this limit in the menu bar")
    }

    private func rowChip(_ row: ProviderRow, showProvider: Bool) -> some View {
        selectButton(row) {
            HStack(spacing: 4) {
                Circle()
                    .fill(thresholdColor(row.limit))
                    .frame(width: 6, height: 6)
                if showProvider {
                    Text(row.providerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(percent(for: row))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(RelativeTime.string(from: Date(), to: row.limit.resetsAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(row.isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
    }

    private func stackedRowView(_ row: ProviderRow) -> some View {
        HStack(spacing: gap) {
            Circle()
                .fill(thresholdColor(row.limit))
                .frame(width: 6, height: 6)
            Text(row.limit.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: gap)
            Text("\(percent(for: row))%")
                .font(.callout.monospacedDigit().weight(.semibold))
            Text(RelativeTime.string(from: Date(), to: row.limit.resetsAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(row.isSelected ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func thresholdColor(_ limit: UsageLimit) -> Color {
        ThresholdColors.color(
            for: ThresholdColors.Level(
                remainingPercent: limit.remainingPercentRounded,
                config: settings.thresholdConfig
            ),
            scheme: colorScheme
        )
    }

    /// No rows anywhere: distinguish an honest empty (ok) from a failure, and
    /// a failure names the provider so the user knows which fix applies.
    @ViewBuilder
    private var emptyOrFailed: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(enabledStores, id: \.name) { provider in
                switch provider.store.state {
                case .failed(let message):
                    Text("\(provider.name): \(message)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    if provider.store.limits?.isEmpty == true {
                        Text("\(provider.name): no usage limits available")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("No usage is shown until a fetch succeeds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    /// Status line only. The quit affordance is the right-click menu, not a
    /// power button here — the panel is for glancing, not for exiting.
    private var footer: some View {
        HStack(spacing: gap) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            if let burst = burstHint {
                Text(burst)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Percentages are moving - refreshing every 10 seconds")
            }
        }
    }

    /// Per-provider status, joined. A disabled provider is not reported: its
    /// state is irrelevant while it is off.
    private var statusText: String {
        let parts = enabledStores.map { provider -> String in
            switch provider.store.state {
            case .idle: return "\(provider.name): not fetched yet"
            case .refreshing: return "\(provider.name): updating…"
            case .ok: return "\(provider.name): updated \(provider.store.lastUpdatedText)"
            case .failed: return "\(provider.name): failed, last good \(provider.store.lastUpdatedText)"
            }
        }
        return parts.isEmpty ? "all providers off" : parts.joined(separator: "  ·  ")
    }

    /// Visible fast-cadence hint, so the burst is something the user can see
    /// rather than a silent traffic change.
    private var burstHint: String? {
        let now = Date()
        let active = enabledStores.contains { provider in
            if let deadline = provider.store.burstDeadline, now < deadline { return true }
            return false
        }
        return active ? "10s" : nil
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
