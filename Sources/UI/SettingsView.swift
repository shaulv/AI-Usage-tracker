import SwiftUI
import ChatGPTUsageCore

/// User preferences window for configuring quota alert thresholds and notifications.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let notificationEngine: UsageNotificationEngine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            thresholdsSection
            Divider()
            notificationsSection
        }
        .padding(20)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage Tracker Settings")
                    .font(.headline)
                Text("Configure alert thresholds and system notifications based on quota remaining.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Status Thresholds (% Usage Left)")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(ThresholdColors.color(for: .warn, scheme: colorScheme))
                        .frame(width: 8, height: 8)
                    Text("Warning Status (Orange)")
                        .font(.callout)
                    Spacer()
                    Text("≤ \(settings.warningRemainingThreshold)% left")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.warningRemainingThreshold) },
                        set: { settings.warningRemainingThreshold = Int($0) }
                    ),
                    in: warningSliderRange,
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(ThresholdColors.color(for: .critical, scheme: colorScheme))
                        .frame(width: 8, height: 8)
                    Text("Critical Alert (Red)")
                        .font(.callout)
                    Spacer()
                    Text("≤ \(settings.criticalRemainingThreshold)% left")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.criticalRemainingThreshold) },
                        set: { settings.criticalRemainingThreshold = Int($0) }
                    ),
                    in: criticalSliderRange,
                    step: 1
                )
            }

            HStack(spacing: 8) {
                badge(
                    color: ThresholdColors.color(for: .ok, scheme: colorScheme),
                    title: "OK",
                    range: "> \(settings.warningRemainingThreshold)%"
                )
                badge(
                    color: ThresholdColors.color(for: .warn, scheme: colorScheme),
                    title: "Warning",
                    range: "\(settings.criticalRemainingThreshold + 1)% - \(settings.warningRemainingThreshold)%"
                )
                badge(
                    color: ThresholdColors.color(for: .critical, scheme: colorScheme),
                    title: "Critical",
                    range: "≤ \(settings.criticalRemainingThreshold)%"
                )
            }
            .padding(.top, 4)
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Native macOS Notifications")
                .font(.subheadline.weight(.semibold))

            Toggle("Enable Usage Notifications", isOn: $settings.notificationsEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Alert when Warning threshold is reached", isOn: $settings.notifyOnWarning)
                Toggle("Alert when Critical threshold is reached", isOn: $settings.notifyOnCritical)
                Toggle("Play notification sound", isOn: $settings.notificationSound)
            }
            .padding(.leading, 18)
            .disabled(!settings.notificationsEnabled)

            HStack {
                Spacer()
                Button("Send Test Notification") {
                    notificationEngine.sendTestNotification()
                }
                .controlSize(.small)
            }
        }
    }

    /// The warning band has to start just above the critical threshold.
    ///
    /// `max(lower, 50)` is load-bearing: `ThresholdConfiguration` allows
    /// critical up to 98, which makes `critical + 1 == 99` and the old
    /// `99...50` an inverted closed range - SwiftUI traps on that with
    /// "Range requires lowerBound <= upperBound". The clamp keeps the range
    /// ordered at every setting while leaving the default 20/10 band alone.
    private var warningSliderRange: ClosedRange<Double> {
        let lower = Double(settings.criticalRemainingThreshold + 1)
        return lower...max(lower, 50)
    }

    /// Same invariant on the critical side: the upper bound is pinned below the
    /// warning threshold and never allowed under 1, so `1...x` can never invert.
    private var criticalSliderRange: ClosedRange<Double> {
        let upper = Double(max(1, min(settings.warningRemainingThreshold - 1, 30)))
        return 1...upper
    }

    private func badge(color: Color, title: String, range: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                Text(range)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
