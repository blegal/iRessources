// iRessources — SPDX-License-Identifier: GPL-3.0-or-later
//
// Power and frequency metrics from IOReport. This is the same data source used
// by `powermetrics`, but it does not require root. Only available on Apple
// silicon; on other machines every value stays nil.

import CSystem
import Foundation
import IOKit

struct ClusterActivity: Hashable {
    var name: String         // IOReport cluster name, e.g. "PCPU", "ECPU", "MCPU0"
    var frequencyMHz: Double? // residency-weighted average while active
    var activeRatio: Double  // fraction of time not idle/down
}

struct PowerSample {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var dramWatts: Double?
    var clusters: [ClusterActivity] = []
    var cores: [String: ClusterActivity] = [:] // keyed by IOReport core name, e.g. "PCPU3"
    var gpuFrequencyMHz: Double?
    var gpuActiveRatio: Double?
}

final class PowerCollector {
    private var subscription: IOReportSubscriptionRef?
    private var subscribed: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime = Date()
    private let frequencyTables: [String: [Double]] // name -> MHz, ascending
    // Some SoC/macOS combinations report zero CPU or ANE energy to unprivileged
    // processes. Until a non-zero value shows up, report "unknown" rather than 0 W.
    private var cpuEnergySeen = false
    private var aneEnergySeen = false

    init() {
        frequencyTables = PowerCollector.readFrequencyTables()
        let groups: [(String, String?)] = [
            ("Energy Model", nil),
            ("CPU Stats", "CPU Complex Performance States"),
            ("CPU Stats", "CPU Core Performance States"),
            ("GPU Stats", "GPU Performance States"),
        ]
        var merged: CFMutableDictionary?
        for (group, subgroup) in groups {
            guard let channels = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0) else {
                continue
            }
            if let merged {
                IOReportMergeChannels(merged, channels, nil)
            } else {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)
            }
        }
        guard let merged else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, merged, &subbed, 0, nil)
        subscribed = subbed?.takeRetainedValue()
        if let subscription, let subscribed {
            previous = IOReportCreateSamples(subscription, subscribed, nil)
        }
    }

    var isAvailable: Bool { subscription != nil }

    func sample() -> PowerSample {
        var result = PowerSample()
        guard let subscription, let subscribed, let previous,
              let current = IOReportCreateSamples(subscription, subscribed, nil)
        else { return result }
        let now = Date()
        let seconds = max(now.timeIntervalSince(previousTime), 0.001)
        defer {
            self.previous = current
            self.previousTime = now
        }
        guard let delta = IOReportCreateSamplesDelta(previous, current, nil),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return result }

        var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0
        var sawEnergy = false

        for channel in channels {
            let item = channel as CFDictionary
            let group = IOReportChannelGetGroup(item) as String? ?? ""
            let subgroup = IOReportChannelGetSubGroup(item) as String? ?? ""
            let name = IOReportChannelGetChannelName(item) as String? ?? ""

            switch (group, subgroup) {
            case ("Energy Model", _):
                let unit = IOReportChannelGetUnitLabel(item) as String? ?? "nJ"
                let joules = Double(IOReportSimpleGetIntegerValue(item, 0)) * Self.joulesPerUnit(unit)
                let watts = joules / seconds
                sawEnergy = true
                if name.hasSuffix("CPU Energy") { cpu += watts }
                else if name == "GPU Energy" { gpu += watts }
                else if name.hasPrefix("ANE") { ane += watts }
                else if name.hasPrefix("DRAM") { dram += watts }
            case ("CPU Stats", "CPU Complex Performance States"):
                // Keep the plain cluster channels (ECPU, PCPU, MCPU0...), skip PCPM/…_IDLE aggregates.
                guard name.hasSuffix("CPU") || name.range(of: #"^[A-Z]CPU\d+$"#, options: .regularExpression) != nil
                else { continue }
                result.clusters.append(activity(of: item, name: name, table: cpuTable(for: item)))
            case ("CPU Stats", "CPU Core Performance States"):
                result.cores[name] = activity(of: item, name: name, table: cpuTable(for: item))
            case ("GPU Stats", "GPU Performance States") where name == "GPUPH":
                let gpuActivity = activity(of: item, name: name, table: frequencyTables["gpu"] ?? [])
                result.gpuFrequencyMHz = gpuActivity.frequencyMHz
                result.gpuActiveRatio = gpuActivity.activeRatio
            default:
                break
            }
        }
        if sawEnergy {
            cpuEnergySeen = cpuEnergySeen || cpu > 0
            aneEnergySeen = aneEnergySeen || ane > 0
            result.cpuWatts = cpuEnergySeen ? cpu : nil
            result.gpuWatts = gpu
            result.aneWatts = aneEnergySeen ? ane : nil
            result.dramWatts = dram > 0 ? dram : nil
        }
        // Clusters that are fully powered down (e.g. a second cluster that is unused) are not interesting.
        result.clusters.removeAll { $0.activeRatio == 0 && $0.frequencyMHz == nil && $0.name.last?.isNumber == true }
        return result
    }

    // MARK: - Residency → frequency

    private func activity(of item: CFDictionary, name: String, table: [Double]) -> ClusterActivity {
        let count = IOReportStateGetCount(item)
        var total = 0.0, active = 0.0, weighted = 0.0
        var activeIndex = 0
        for i in 0..<count {
            let state = IOReportStateGetNameForIndex(item, i) as String? ?? ""
            let residency = Double(IOReportStateGetResidency(item, i))
            total += residency
            if ["IDLE", "DOWN", "OFF", "NON_IDLE"].contains(state) { continue }
            active += residency
            if !table.isEmpty {
                weighted += residency * table[min(activeIndex, table.count - 1)]
            }
            activeIndex += 1
        }
        return ClusterActivity(
            name: name,
            frequencyMHz: active > 0 && !table.isEmpty ? weighted / active : nil,
            activeRatio: total > 0 ? active / total : 0
        )
    }

    private func cpuTable(for item: CFDictionary) -> [Double] {
        let states = (0..<IOReportStateGetCount(item)).compactMap { IOReportStateGetNameForIndex(item, $0) as String? }
        let performanceStates = states.filter { !["IDLE", "DOWN", "OFF", "NON_IDLE"].contains($0) }.count
        return frequencyTables["cpu\(performanceStates)"] ?? []
    }

    private static func joulesPerUnit(_ unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        default: return 1e-9
        }
    }

    /// Reads the DVFS tables published by the power manager in the device tree.
    /// CPU tables are keyed by their number of states ("cpu15", "cpu20"…) because
    /// the property indices change between SoC generations; the GPU table is the
    /// historical `voltage-states9`.
    private static func readFrequencyTables() -> [String: [Double]] {
        let pmgr = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard pmgr != 0 else { return [:] }
        defer { IOObjectRelease(pmgr) }

        var tables: [String: [Double]] = [:]
        for (key, value) in IORegistry.properties(of: pmgr) {
            guard key.hasPrefix("voltage-states"), let data = value as? Data, data.count >= 8 else { continue }
            let raw: [UInt32] = data.withUnsafeBytes { buffer in
                stride(from: 0, to: buffer.count - 7, by: 8).map { buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self) }
            }
            let nonZero = raw.filter { $0 > 1 }
            guard let top = nonZero.max(), top > 100_000 else { continue }
            // Old SoCs publish Hz, newer ones kHz.
            let mhz = nonZero.map { top > 100_000_000 ? Double($0) / 1_000_000 : Double($0) / 1_000 }

            if key == "voltage-states9" {
                tables["gpu"] = mhz
            } else if key.hasSuffix("-sram") || top < 100_000_000 {
                // CPU clusters run above 2 GHz on every Apple silicon generation.
                guard (mhz.max() ?? 0) > 2_000 else { continue }
                let name = "cpu\(mhz.count)"
                if let existing = tables[name], (existing.max() ?? 0) >= (mhz.max() ?? 0) { continue }
                tables[name] = mhz
            }
        }
        return tables
    }
}
