// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit
import IOKit.ps

struct BatterySample {
    var charge: Double              // 0...1
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycleCount: Int?
    var designCapacity: Int?        // mAh
    var maxCapacity: Int?           // mAh, current full-charge capacity
    var currentCapacity: Int?       // mAh
    var voltage: Double?            // V
    var amperage: Double?           // A, negative while discharging
    var temperature: Double?        // °C
    var adapterWatts: Int?
    var adapterName: String?
    var manufacturer: String?
    var model: String?
    var serial: String?
    var condition: String?

    var health: Double? {
        guard let design = designCapacity, let max = maxCapacity, design > 0 else { return nil }
        return Double(max) / Double(design)
    }

    var watts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }
}

final class BatteryCollector {
    func sample() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        var description: [String: Any]?
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            description = desc
        }
        guard let description else { return nil }

        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
        let toEmpty = description[kIOPSTimeToEmptyKey] as? Int
        let toFull = description[kIOPSTimeToFullChargeKey] as? Int

        var sample = BatterySample(
            charge: max > 0 ? Double(current) / Double(max) : 0,
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
            isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            isFullyCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
            minutesToEmpty: toEmpty.flatMap { $0 > 0 ? $0 : nil },
            minutesToFull: toFull.flatMap { $0 > 0 ? $0 : nil },
            condition: description["BatteryHealth"] as? String
        )

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            sample.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            sample.adapterName = adapter["Name"] as? String
        }

        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            defer { IOObjectRelease(battery) }
            let props = IORegistry.properties(of: battery)
            // Recent macOS versions move most values into the "BatteryData" dictionary.
            let data = props["BatteryData"] as? [String: Any] ?? [:]
            func int(_ key: String) -> Int? { ((props[key] ?? data[key]) as? NSNumber)?.intValue }
            sample.cycleCount = int("CycleCount")
            sample.designCapacity = int("DesignCapacity")
            sample.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
            sample.currentCapacity = int("AppleRawCurrentCapacity")
            sample.voltage = int("Voltage").map { Double($0) / 1000 }
            // Amperage is a signed 64-bit value stored in an unsigned CFNumber on some models.
            if let amperage = (props["InstantAmperage"] ?? props["Amperage"]) as? NSNumber {
                sample.amperage = Double(Int64(truncatingIfNeeded: amperage.int64Value)) / 1000
            }
            sample.temperature = (int("Temperature") ?? int("VirtualTemperature")).map { Double($0) / 100 }
            sample.manufacturer = props["Manufacturer"] as? String
            sample.model = props["DeviceName"] as? String
            sample.serial = props["Serial"] as? String ?? props["BatterySerialNumber"] as? String
        }
        return sample
    }
}
