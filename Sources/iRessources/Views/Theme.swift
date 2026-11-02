// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Colour palette for every resource plus optional window colours. Themes that
/// define their own backgrounds also force the matching light/dark appearance.
struct Theme: Identifiable, Equatable {
    var id: String
    var name: String
    var cpu: Color
    var memory: Color
    var swap: Color
    var gpu: Color
    var npu: Color
    var drive: Color
    var network: Color
    var networkSend: Color
    var battery: Color
    var power: Color
    var danger: Color = Color(hex: 0xE01B24)
    var warning: Color = Color(hex: 0xE66100)
    var success: Color = Color(hex: 0x26A269)
    var windowBackground: Color?
    var sidebarBackground: Color?
    var cardBackground: Color?
    var colorScheme: ColorScheme?

    /// Defaults close to GNOME's palette, which Resources uses.
    static let adwaita = Theme(
        id: "adwaita", name: "Adwaita",
        cpu: Color(hex: 0x3584E4), memory: Color(hex: 0xC061CB), swap: Color(hex: 0x9141AC),
        gpu: Color(hex: 0xE01B24), npu: Color(hex: 0x9141AC), drive: Color(hex: 0xFF7800),
        network: Color(hex: 0x2190A4), networkSend: Color(hex: 0x1A6C7A), battery: Color(hex: 0x2EC27E),
        power: Color(hex: 0xE5A50A)
    )

    static let macOS = Theme(
        id: "macos", name: "macOS",
        cpu: .blue, memory: .purple, swap: .indigo, gpu: .red, npu: .mint, drive: .orange,
        network: .teal, networkSend: .cyan, battery: .green, power: .yellow, danger: .red
    )

    static let pastel = Theme(
        id: "pastel", name: "Pastel",
        cpu: Color(hex: 0x7EA6E0), memory: Color(hex: 0xD99AD8), swap: Color(hex: 0xB49BDB),
        gpu: Color(hex: 0xF08C8C), npu: Color(hex: 0x9ED8C6), drive: Color(hex: 0xF5B97A),
        network: Color(hex: 0x7CCBD1), networkSend: Color(hex: 0x6AA9C9), battery: Color(hex: 0x95D5A0),
        power: Color(hex: 0xF2D27C), danger: Color(hex: 0xE57373)
    )

    static let nord = Theme(
        id: "nord", name: "Nord",
        cpu: Color(hex: 0x81A1C1), memory: Color(hex: 0xB48EAD), swap: Color(hex: 0x9C7FA0),
        gpu: Color(hex: 0xBF616A), npu: Color(hex: 0x8FBCBB), drive: Color(hex: 0xD08770),
        network: Color(hex: 0x88C0D0), networkSend: Color(hex: 0x5E81AC), battery: Color(hex: 0xA3BE8C),
        power: Color(hex: 0xEBCB8B), danger: Color(hex: 0xBF616A),
        windowBackground: Color(hex: 0x2E3440), sidebarBackground: Color(hex: 0x272C36),
        cardBackground: Color(hex: 0x3B4252), colorScheme: .dark
    )

    static let dracula = Theme(
        id: "dracula", name: "Dracula",
        cpu: Color(hex: 0xBD93F9), memory: Color(hex: 0xFF79C6), swap: Color(hex: 0xD6ACFF),
        gpu: Color(hex: 0xFF5555), npu: Color(hex: 0x8BE9FD), drive: Color(hex: 0xFFB86C),
        network: Color(hex: 0x8BE9FD), networkSend: Color(hex: 0x6272A4), battery: Color(hex: 0x50FA7B),
        power: Color(hex: 0xF1FA8C), danger: Color(hex: 0xFF5555),
        windowBackground: Color(hex: 0x282A36), sidebarBackground: Color(hex: 0x21222C),
        cardBackground: Color(hex: 0x343746), colorScheme: .dark
    )

    static let solarized = Theme(
        id: "solarized", name: "Solarized",
        cpu: Color(hex: 0x268BD2), memory: Color(hex: 0xD33682), swap: Color(hex: 0x6C71C4),
        gpu: Color(hex: 0xDC322F), npu: Color(hex: 0x2AA198), drive: Color(hex: 0xCB4B16),
        network: Color(hex: 0x2AA198), networkSend: Color(hex: 0x268BD2), battery: Color(hex: 0x859900),
        power: Color(hex: 0xB58900), danger: Color(hex: 0xDC322F),
        windowBackground: Color(hex: 0xFDF6E3), sidebarBackground: Color(hex: 0xEEE8D5),
        cardBackground: Color(hex: 0xFFFBF0), colorScheme: .light
    )

    static let graphite = Theme(
        id: "graphite", name: "Graphite",
        cpu: Color(hex: 0x8E8E93), memory: Color(hex: 0x8E8E93), swap: Color(hex: 0x6E6E73),
        gpu: Color(hex: 0x8E8E93), npu: Color(hex: 0x8E8E93), drive: Color(hex: 0x8E8E93),
        network: Color(hex: 0x8E8E93), networkSend: Color(hex: 0x636366), battery: Color(hex: 0x8E8E93),
        power: Color(hex: 0x8E8E93), danger: Color(hex: 0xD70015)
    )

    static let all: [Theme] = [.adwaita, .macOS, .pastel, .nord, .dracula, .solarized, .graphite]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? .adwaita }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.adwaita
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// User preferences shared by every view.
enum Preferences {
    static let theme = "theme"
    static let appearance = "appearance"
    static let animations = "animations"
    static let smoothGraphs = "smoothGraphs"
    static let sidebarGraphs = "sidebarGraphs"
    static let normalizeCPU = "normalizeCPU"
    static let appIcon = "appIcon"
}

/// Animation helper honouring both the in-app switch and the system's Reduce Motion.
struct Motion {
    var enabled: Bool

    func animation(_ animation: Animation = .smooth(duration: 0.3)) -> Animation? {
        enabled ? animation : nil
    }
}

private struct MotionKey: EnvironmentKey {
    static let defaultValue = Motion(enabled: true)
}

extension EnvironmentValues {
    var motion: Motion {
        get { self[MotionKey.self] }
        set { self[MotionKey.self] = newValue }
    }
}

/// Applies the theme, appearance and motion settings to a view hierarchy.
struct ThemedRoot: ViewModifier {
    @AppStorage(Preferences.theme) private var themeID = Theme.adwaita.id
    @AppStorage(Preferences.appearance) private var appearance = AppearanceMode.system
    @AppStorage(Preferences.animations) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let theme = Theme.named(themeID)
        content
            .environment(\.theme, theme)
            .environment(\.motion, Motion(enabled: animations && !reduceMotion))
            .preferredColorScheme(theme.colorScheme ?? appearance.scheme)
            .tint(theme.cpu)
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
