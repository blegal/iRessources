// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func bytes(_ value: Int?) -> String {
        value.map { bytes(UInt64($0)) } ?? "—"
    }

    static func storage(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "0 B/s" }
        if bytesPerSecond < 1000 { return "\(Int(bytesPerSecond)) B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }

    static func bits(_ bitsPerSecond: UInt64) -> String {
        let units = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"]
        var value = Double(bitsPerSecond)
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: value < 10 && index > 0 ? "%.1f %@" : "%.0f %@", value, units[index])
    }

    static func percent(_ ratio: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f %%", ratio * 100)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.2f W", value) : String(format: "%.1f W", value)
    }

    static func megahertz(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return value >= 1000 ? String(format: "%.2f GHz", value / 1000) : String(format: "%.0f MHz", value)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f °C", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour, .minute] : [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 3
        return formatter.string(from: seconds) ?? "—"
    }

    static func minutes(_ minutes: Int?) -> String {
        guard let minutes else { return "—" }
        return duration(TimeInterval(minutes * 60))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
