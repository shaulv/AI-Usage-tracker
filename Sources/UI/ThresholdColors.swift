import SwiftUI

/// Per-appearance threshold colors.
///
/// Rule: a component that reads well in dark but fails in light gets its own
/// tokens. A single fixed hex cannot pass 4.5:1 on both a light and a dark
/// surface, so these are two sets, not one.
///
/// Ratios computed with the WCAG relative-luminance formula against
/// #FFFFFF (light) and #1C1C1E (dark):
///
///   ok       light #17653A  7.10    dark #4ADE80  9.76
///   warn     light #8A5300  6.33    dark #F0B429  9.13
///   critical light #B02418  6.75    dark #FF6B5E  6.09
///
/// Those are ratios against flat panel backgrounds. A vibrancy-backed
/// MenuBarExtra surface is not flat, so this must be re-measured on the real
/// rendered panel before the colors are called done. Do not assert a ratio,
/// compute it on the ground it is used on.
enum ThresholdColors {
    enum Level {
        case ok, warn, critical

        init(usedFraction: Double) {
            if usedFraction >= 0.90 {
                self = .critical
            } else if usedFraction >= 0.70 {
                self = .warn
            } else {
                self = .ok
            }
        }
    }

    static func color(for level: Level, scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            switch level {
            case .ok: return hex(0x4ADE80)
            case .warn: return hex(0xF0B429)
            case .critical: return hex(0xFF6B5E)
            }
        default:
            switch level {
            case .ok: return hex(0x17653A)
            case .warn: return hex(0x8A5300)
            case .critical: return hex(0xB02418)
            }
        }
    }

    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
