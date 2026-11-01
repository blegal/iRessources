// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.motion) private var motion
    @AppStorage(Preferences.theme) private var themeID = Theme.adwaita.id
    @AppStorage(Preferences.appearance) private var appearance = AppearanceMode.system
    @AppStorage(Preferences.animations) private var animations = true
    @AppStorage(Preferences.smoothGraphs) private var smoothGraphs = false
    @AppStorage(Preferences.normalizeCPU) private var normalizeCPU = true
    @AppStorage(Preferences.sidebarGraphs) private var sidebarGraphs = true

    private let intervals: [(String, TimeInterval)] = [
        ("Very fast (0.5 s)", 0.5), ("Fast (1 s)", 1), ("Normal (2 s)", 2), ("Slow (3 s)", 3), ("Very slow (5 s)", 5),
    ]

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            performanceTab
                .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.33percent") }
        }
        .frame(width: 520)
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(Theme.all) { theme in
                        ThemeSwatch(theme: theme, isSelected: theme.id == themeID)
                            .onTapGesture {
                                withAnimation(motion.animation()) { themeID = theme.id }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(Theme.named(themeID).colorScheme != nil)
                if Theme.named(themeID).colorScheme != nil {
                    Text("This theme uses its own background, so it always appears \(Theme.named(themeID).colorScheme == .dark ? "dark" : "light").")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show graphs in the sidebar", isOn: $sidebarGraphs)
            }
            Section {
                Toggle("Animations", isOn: $animations)
                Toggle("Animate live data", isOn: $smoothGraphs)
                    .disabled(!animations)
                Text("Animations cover page transitions, the sidebar highlight and appearing content; they "
                     + "cost almost nothing. Animating live data makes graphs scroll smoothly and numbers roll "
                     + "on every refresh, which uses several times more CPU. Both follow “Reduce motion” in "
                     + "System Settings › Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Performance

    private var performanceTab: some View {
        Form {
            Section {
                Picker("Refresh interval", selection: Binding(
                    get: { monitor.refreshInterval },
                    set: {
                        monitor.refreshInterval = $0
                        UserDefaults.standard.set($0, forKey: "refreshInterval")
                    }
                )) {
                    ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
                }
                Text("Longer intervals use less energy. While the window is hidden, iRessources refreshes "
                     + "at most every 5 seconds and skips the process list, sensors and power metrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Divide CPU usage by the number of cores", isOn: $normalizeCPU)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A miniature of the sidebar graphs in the theme's colours.
private struct ThemeSwatch: View {
    var theme: Theme
    var isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let samples: [[Double]] = [
        [0.2, 0.35, 0.25, 0.6, 0.4, 0.3, 0.5, 0.45],
        [0.55, 0.55, 0.56, 0.56, 0.57, 0.56, 0.57, 0.57],
        [0.1, 0.4, 0.2, 0.15, 0.7, 0.2, 0.3, 0.25],
        [0.05, 0.05, 0.8, 0.1, 0.05, 0.6, 0.05, 0.1],
    ]

    var body: some View {
        let colors = [theme.cpu, theme.memory, theme.gpu, theme.network]
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    MiniGraph(values: Self.samples[index], color: colors[index])
                        .frame(height: 14)
                }
            }
            .padding(6)
            .background(theme.windowBackground ?? (colorScheme == .dark ? Color(white: 0.16) : .white),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(theme.name).font(.callout)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? theme.cpu : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(theme.name)
    }
}

private struct MiniGraph: View {
    var values: [Double]
    var color: Color

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value)))
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.15)))
            context.fill(area, with: .color(color.opacity(0.45)))
            context.stroke(line, with: .color(color), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
