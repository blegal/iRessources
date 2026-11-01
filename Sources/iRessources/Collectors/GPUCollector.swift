// iRessources — SPDX-License-Identifier: GPL-3.0-or-later
//
// GPU utilisation comes from the `PerformanceStatistics` dictionary that every
// IOAccelerator publishes. Per-process GPU time comes from the accelerator's
// user clients, which record the accumulated GPU time of each Metal client.

import Foundation
import IOKit

struct GPUSample: Identifiable {
    var id: UInt64               // registry entry ID of the accelerator
    var name: String
    var vendor: String
    var cores: Int?
    var deviceUtilization: Double?   // 0...1
    var rendererUtilization: Double?
    var tilerUtilization: Double?
    var memoryUsed: UInt64?
    var memoryAllocated: UInt64?
    var hasUnifiedMemory: Bool
}

final class GPUCollector {
    private var previousGPUTime: [pid_t: UInt64] = [:]
    private var previousTime = Date()

    func sample() -> [GPUSample] {
        var gpus: [GPUSample] = []
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            let props = IORegistry.properties(of: accelerator)
            let stats = props["PerformanceStatistics"] as? [String: Any] ?? [:]
            let id = IORegistry.entryID(accelerator)

            let name = ioString(props["model"]) ?? ioString(IORegistry.searchProperty("model", of: accelerator)) ?? "GPU"

            func ratio(_ key: String) -> Double? { (stats[key] as? NSNumber).map { $0.doubleValue / 100 } }
            func bytes(_ keys: String...) -> UInt64? {
                for key in keys { if let value = stats[key] as? NSNumber { return value.uint64Value } }
                return nil
            }

            gpus.append(GPUSample(
                id: id,
                name: name,
                vendor: Self.vendor(for: props, name: name),
                cores: ioInt(props["gpu-core-count"]),
                deviceUtilization: ratio("Device Utilization %") ?? ratio("GPU Activity(%)"),
                rendererUtilization: ratio("Renderer Utilization %"),
                tilerUtilization: ratio("Tiler Utilization %"),
                memoryUsed: bytes("In use system memory", "vramUsedBytes"),
                memoryAllocated: bytes("Alloc system memory", "vramFreeBytes"),
                // Apple silicon GPUs share system memory; discrete GPUs report VRAM counters.
                hasUnifiedMemory: stats["vramUsedBytes"] == nil
            ))
        }
        return gpus
    }

    /// GPU usage (0...1) for each process that submitted GPU work since the last call.
    func processUsage() -> [pid_t: Double] {
        var gpuTime: [pid_t: UInt64] = [:]
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            IORegistry.children(of: accelerator) { client in
                guard let creator = IORegistry.property("IOUserClientCreator", of: client) as? String,
                      let pid = Self.pid(fromCreator: creator),
                      let usage = IORegistry.property("AppUsage", of: client) as? [[String: Any]]
                else { return }
                let total = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                gpuTime[pid, default: 0] += total
            }
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(previousTime) * 1e9
        var result: [pid_t: Double] = [:]
        if elapsed > 0 {
            for (pid, time) in gpuTime {
                guard let before = previousGPUTime[pid], time > before else { continue }
                result[pid] = min(Double(time - before) / elapsed, 1)
            }
        }
        previousGPUTime = gpuTime
        previousTime = now
        return result
    }

    private static func pid(fromCreator creator: String) -> pid_t? {
        // Format: "pid 1234, ProcessName"
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    private static func vendor(for props: [String: Any], name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("apple") { return "Apple" }
        if lower.contains("amd") || lower.contains("radeon") { return "AMD" }
        if lower.contains("intel") { return "Intel" }
        if lower.contains("nvidia") || lower.contains("geforce") { return "NVIDIA" }
        return (props["IOClass"] as? String) ?? "Unknown"
    }
}
