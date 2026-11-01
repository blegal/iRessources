// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Graph

/// Resources-style graph: a tinted rounded background with a filled area and a
/// line on top. Values are drawn with shapes so the optional smooth scrolling
/// can animate a single phase value instead of re-laying out views.
struct GraphView: View {
    struct Series {
        var values: [Double]
        var color: Color
    }

    var series: [Series]
    /// Fixed upper bound; nil scales to the visible peak.
    var maximum: Double?
    /// Lower bound for the auto-scaled maximum, so idle traffic does not fill the graph.
    var minimumScale: Double = 1
    var cornerRadius: CGFloat = 6

    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Preferences.smoothGraphs) private var smoothGraphs = false
    @State private var phase: CGFloat = 0

    init(_ values: [Double], color: Color, maximum: Double? = 1, minimumScale: Double = 1) {
        series = [Series(values: values, color: color)]
        self.maximum = maximum
        self.minimumScale = minimumScale
    }

    init(series: [Series], maximum: Double? = nil, minimumScale: Double = 1) {
        self.series = series
        self.maximum = maximum
        self.minimumScale = minimumScale
    }

    private var scale: Double {
        if let maximum { return maximum }
        let peak = series.map { $0.values.max() ?? 0 }.max() ?? 0
        return max(peak * 1.1, minimumScale)
    }

    var body: some View {
        let scale = self.scale
        let base = series.first?.color ?? .accentColor
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(base.opacity(colorScheme == .dark ? 0.16 : 0.13))
            ForEach(series.indices, id: \.self) { index in
                let serie = series[index]
                GraphShape(values: serie.values, scale: scale, phase: phase, closed: true)
                    .fill(serie.color.opacity(colorScheme == .dark ? 0.45 : 0.4))
                GraphShape(values: serie.values, scale: scale, phase: phase, closed: false)
                    .stroke(serie.color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onChange(of: monitor.lastUpdate) {
            guard smoothGraphs, motion.enabled else { return }
            // Start one step to the right and glide left during the refresh interval.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { phase = 1 }
            withAnimation(.linear(duration: monitor.refreshInterval)) { phase = 0 }
        }
        .accessibilityHidden(true)
    }
}

private struct GraphShape: Shape {
    var values: [Double]
    var scale: Double
    var phase: CGFloat
    var closed: Bool

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, scale > 0 else { return path }
        let step = rect.width / CGFloat(History.capacity - 1)
        let start = rect.minX + CGFloat(History.capacity - values.count) * step + phase * step
        let height = rect.height - 1

        for (index, value) in values.enumerated() {
            let point = CGPoint(x: start + CGFloat(index) * step,
                                y: rect.maxY - CGFloat(min(max(value / scale, 0), 1)) * height)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        if closed {
            path.addLine(to: CGPoint(x: start + CGFloat(values.count - 1) * step, y: rect.maxY))
            path.addLine(to: CGPoint(x: start, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Boxed lists (libadwaita style)

/// A titled group, like the "Usage" and "Properties" sections of Resources.
struct PageSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
    }
}

/// Rounded card whose direct children are separated by hairlines.
struct BoxedList<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 { Divider().opacity(0.6) }
                    subview
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.08)))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 3, y: 1)
    }

    private var cardBackground: Color {
        theme.cardBackground ?? (colorScheme == .dark ? Color.white.opacity(0.07) : Color.white)
    }
}

/// Caption above a value, as used for every property row in Resources.
struct PropertyRow: View {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// A graph with its caption and current value underneath.
struct GraphRow: View {
    var label: String
    var value: String
    var graph: GraphView
    var height: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            graph.frame(height: height)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                AnimatedText(value)
            }
        }
        .padding(14)
    }
}

/// Text whose digits roll when the value changes. Animating every value on
/// every refresh costs real CPU, so it only happens with live animations on.
struct AnimatedText: View {
    var text: String
    @Environment(\.motion) private var motion
    @AppStorage(Preferences.smoothGraphs) private var liveAnimations = false

    init(_ text: String) { self.text = text }

    var body: some View {
        let animated = liveAnimations && motion.enabled
        Text(text)
            .monospacedDigit()
            .contentTransition(animated ? .numericText() : .identity)
            .animation(animated ? .snappy(duration: 0.35) : nil, value: text)
    }
}

struct ToggleRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Text(title) }
            .toggleStyle(.switch)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

/// Scrollable page with a centred column, the frame of every device view.
struct Page<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .opacity(appeared || !motion.enabled ? 1 : 0)
            .offset(y: appeared || !motion.enabled ? 0 : 10)
        }
        .background(theme.windowBackground ?? Color(nsColor: .windowBackgroundColor))
        .centeredTitle(title, subtitle: subtitle)
        .onAppear {
            withAnimation(motion.animation(.smooth(duration: 0.35))) { appeared = true }
        }
    }
}

extension View {
    /// Title and subtitle centred in the toolbar, as in libadwaita header bars.
    func centeredTitle(_ title: String, subtitle: String?) -> some View {
        modifier(CenteredTitle(title: title, subtitle: subtitle))
    }
}

private struct CenteredTitle: ViewModifier {
    var title: String
    var subtitle: String?
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minWidth: 200)
                }
            }
            .toolbarBackground(theme.windowBackground.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.bar), for: .windowToolbar)
            .toolbarBackgroundVisibility(theme.windowBackground == nil ? .automatic : .visible, for: .windowToolbar)
    }
}

struct UsageBar: View {
    var ratio: Double
    var color: Color
    @Environment(\.motion) private var motion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color).frame(width: proxy.size.width * CGFloat(min(max(ratio, 0), 1)))
            }
            .animation(motion.animation(), value: (ratio * 100).rounded())
        }
        .frame(height: 6)
    }
}

// MARK: - Buttons

/// Destructive pill button, like libadwaita's "End App".
struct DestructivePillStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.danger.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(theme.danger.opacity(configuration.isPressed ? 0.28 : 0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CircleIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08), in: Circle())
    }
}

// MARK: - Icons

/// Caches application icons so the process tables do not hit LaunchServices on every refresh.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forBundle path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        icons[path] = icon
        return icon
    }

    /// The enclosing ".app" bundle of an executable path, if any.
    static func bundlePath(forExecutable path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

struct ProcessIcon: View {
    var executablePath: String?
    var bundlePath: String?
    var size: CGFloat = 16

    var body: some View {
        if let bundle = bundlePath ?? IconCache.bundlePath(forExecutable: executablePath) {
            Image(nsImage: IconCache.icon(forBundle: bundle))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
