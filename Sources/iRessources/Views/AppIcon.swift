// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The app icons offered in Settings. `pulse` is the one in the bundle; the
/// others replace the Dock icon while the app runs.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case pulse, gauge, chip, bars

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pulse: "Pulse"
        case .gauge: "Gauge"
        case .chip: "Chip"
        case .bars: "Bars"
        }
    }

    /// Shows the chosen icon in the Dock and the app switcher.
    @MainActor
    func apply() {
        NSApp.applicationIconImage = self == .pulse ? nil : image(size: 512)
    }

    @MainActor
    func image(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView(style: self, padded: true).frame(width: size, height: size))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Writes the iconset of the bundle icon; `scripts/build-app.sh` turns it into an .icns.
    @MainActor
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(points * scale)
                let renderer = ImageRenderer(content: AppIconView(style: .pulse, padded: true).frame(width: pixels, height: pixels))
                renderer.scale = 1
                guard let image = renderer.cgImage else { continue }
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try data?.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}

/// Draws an icon on a 100×100 grid whose rounded square spans 6...94. With
/// `padded`, it follows the macOS grid instead: an 824-point square centred
/// on a 1024-point canvas, with a soft shadow.
struct AppIconView: View {
    var style: AppIconStyle
    var padded = false

    var body: some View {
        Canvas { context, size in
            let unit = padded ? size.width * 824 / 1024 / 88 : size.width / 100
            let origin = (size.width - 100 * unit) / 2
            context.translateBy(x: origin, y: origin)
            context.scaleBy(x: unit, y: unit)
            let tile = Path(roundedRect: CGRect(x: 6, y: 6, width: 88, height: 88), cornerRadius: 20, style: .continuous)
            if padded {
                var shadow = context
                shadow.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.2, y: 0.8))
                shadow.fill(tile, with: .color(.black))
            }
            context.clip(to: tile)
            switch style {
            case .pulse: Self.pulse(&context)
            case .gauge: Self.gauge(&context, tile: tile)
            case .chip: Self.chip(&context)
            case .bars: Self.bars(&context, tile: tile)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private static let blue = Color(hex: 0x3584E4)
    private static let purple = Color(hex: 0xC061CB)
    private static let green = Color(hex: 0x2EC27E)
    private static let orange = Color(hex: 0xFF7800)
    private static let red = Color(hex: 0xE01B24)
    private static let ink = Color(hex: 0x241F31)

    private static func line(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        return path
    }

    private static func area(_ points: [(CGFloat, CGFloat)], bottom: CGFloat) -> Path {
        var path = line(points)
        path.addLine(to: CGPoint(x: points.last!.0, y: bottom))
        path.addLine(to: CGPoint(x: points.first!.0, y: bottom))
        path.closeSubpath()
        return path
    }

    /// Stacked live graphs, after Activity Monitor and the Resources sidebar.
    private static func pulse(_ context: inout GraphicsContext) {
        context.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(Color(hex: 0x1E2230)))
        context.fill(Path(roundedRect: CGRect(x: 16, y: 18, width: 68, height: 64), cornerRadius: 8, style: .continuous),
                     with: .color(Color(hex: 0x272C3D)))
        var screen = context
        screen.clip(to: Path(roundedRect: CGRect(x: 16, y: 18, width: 68, height: 64), cornerRadius: 8, style: .continuous))
        let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        // Back to front, so each area keeps its own colour.
        let gpu: [(CGFloat, CGFloat)] = [(16, 58), (26, 54), (36, 60), (46, 40), (56, 46), (66, 30), (76, 38), (84, 34)]
        screen.fill(area(gpu, bottom: 82), with: .color(purple.opacity(0.4)))
        screen.stroke(line(gpu), with: .color(purple), style: stroke)
        let memory: [(CGFloat, CGFloat)] = [(16, 70), (28, 64), (38, 67), (48, 52), (58, 58), (68, 44), (84, 48)]
        screen.fill(area(memory, bottom: 82), with: .color(Color(hex: 0x1F5E4A)))
        screen.stroke(line(memory), with: .color(green), style: stroke)
        let cpu: [(CGFloat, CGFloat)] = [(16, 46), (24, 44), (30, 50), (38, 26), (44, 40), (54, 36), (62, 22), (72, 32), (84, 26)]
        screen.stroke(line(cpu), with: .color(blue), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    /// A dial in the resource colours, after GNOME System Monitor and iStat Menus.
    private static func gauge(_ context: inout GraphicsContext, tile: Path) {
        context.fill(tile, with: .color(Color(hex: 0xF6F5F4)))
        context.stroke(tile, with: .color(Color(hex: 0xDEDDDA)), lineWidth: 1)
        let centre = CGPoint(x: 50, y: 64)
        let segments: [(Double, Double, Color)] = [(180, 223, blue), (227, 268, purple), (272, 313, orange), (317, 360, red)]
        for (start, end, color) in segments {
            var arc = Path()
            arc.addArc(center: centre, radius: 28, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            context.stroke(arc, with: .color(color), lineWidth: 9)
        }
        context.stroke(line([(50, 64), (64, 46)]), with: .color(ink), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: 44.5, y: 58.5, width: 11, height: 11)), with: .color(ink))
        context.fill(Path(roundedRect: CGRect(x: 30, y: 74, width: 40, height: 6), cornerRadius: 3), with: .color(Color(hex: 0xDEDDDA)))
    }

    /// A processor with a load curve, after Mission Center and Task Manager.
    private static func chip(_ context: inout GraphicsContext) {
        context.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(blue))
        var pins = Path()
        for offset: CGFloat in [38, 50, 62] {
            pins.addLines([CGPoint(x: offset, y: 18), CGPoint(x: offset, y: 26)])
            pins.addLines([CGPoint(x: offset, y: 74), CGPoint(x: offset, y: 82)])
            pins.addLines([CGPoint(x: 18, y: offset), CGPoint(x: 26, y: offset)])
            pins.addLines([CGPoint(x: 74, y: offset), CGPoint(x: 82, y: offset)])
        }
        context.stroke(pins, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let die = Path(roundedRect: CGRect(x: 26, y: 26, width: 48, height: 48), cornerRadius: 8, style: .continuous)
        context.fill(die, with: .color(Color(hex: 0x1A5FB4)))
        context.stroke(die, with: .color(.white), lineWidth: 2.5)
        context.stroke(line([(31, 58), (38, 58), (42, 46), (48, 64), (54, 38), (59, 54), (63, 50), (69, 50)]),
                       with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    /// Resource bars in the Resources palette, after Task Manager and btop.
    private static func bars(_ context: inout GraphicsContext, tile: Path) {
        context.fill(tile, with: .color(.white))
        context.stroke(tile, with: .color(Color(hex: 0xDEDDDA)), lineWidth: 1)
        let bars: [(CGFloat, CGFloat, Color)] = [(20, 44, blue), (35, 28, purple), (50, 52, orange), (65, 22, green)]
        for (x, top, color) in bars {
            context.fill(Path(roundedRect: CGRect(x: x, y: top, width: 11, height: 78 - top), cornerRadius: 5.5), with: .color(color))
        }
        context.stroke(line([(20, 34), (36, 22), (52, 36), (80, 16)]), with: .color(ink.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}
