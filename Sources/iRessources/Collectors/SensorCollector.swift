// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import CSystem
import Foundation

struct TemperatureReading: Hashable, Identifiable {
    var id: String { name }
    var name: String
    var celsius: Double
}

struct TemperatureSample {
    var sensors: [TemperatureReading] = []

    /// Hottest SoC die sensor (CPU/GPU complex on Apple silicon).
    var soc: Double? { max(matching: ["tdie", "tdev", "SOC", "CPU", "GPU"]) }
    var storage: Double? { max(matching: ["NAND"]) }
    var battery: Double? { max(matching: ["battery", "gas gauge"]) }

    private func max(matching needles: [String]) -> Double? {
        sensors.filter { sensor in needles.contains { sensor.name.localizedCaseInsensitiveContains($0) } }
            .map(\.celsius).max()
    }
}

final class SensorCollector {
    private var buffer = [csys_temperature](repeating: csys_temperature(), count: 256)

    func sample() -> TemperatureSample {
        let count = Int(csys_read_temperatures(&buffer, Int32(buffer.count)))
        var byName: [String: Double] = [:]
        for i in 0..<count {
            let name = withUnsafeBytes(of: buffer[i].name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            // Several services may share a product name; keep the hottest.
            byName[name] = Swift.max(byName[name] ?? 0, buffer[i].celsius)
        }
        return TemperatureSample(sensors: byName.map { TemperatureReading(name: $0.key, celsius: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
