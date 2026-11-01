// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import IOKit

struct PerformanceLevel: Hashable {
    var name: String
    var logicalCPUs: Int
    var physicalCPUs: Int
    var l2Cache: Int?
}

struct CPUInfo {
    var model: String
    var architecture: String
    var physicalCores: Int
    var logicalCores: Int
    var performanceLevels: [PerformanceLevel]
    /// Cluster type letter for each logical CPU, read from the device tree ("P", "E", "M"…).
    var coreClusters: [String]
    var l1iCache: Int?
    var l1dCache: Int?
    var l2Cache: Int?
    var l3Cache: Int?
    var bootTime: Date?

    static func read() -> CPUInfo {
        var levels: [PerformanceLevel] = []
        for i in 0..<(Sysctl.int("hw.nperflevels") ?? 0) {
            let prefix = "hw.perflevel\(i)"
            levels.append(PerformanceLevel(
                name: Sysctl.string("\(prefix).name") ?? "Level \(i)",
                logicalCPUs: Sysctl.int("\(prefix).logicalcpu") ?? 0,
                physicalCPUs: Sysctl.int("\(prefix).physicalcpu") ?? 0,
                l2Cache: Sysctl.int("\(prefix).l2cachesize")
            ))
        }

        var bootTime: Date?
        if let tv = Sysctl.value("kern.boottime", initial: timeval()) {
            bootTime = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
        }

        let l3 = Sysctl.int("hw.l3cachesize").flatMap { $0 > 0 ? $0 : nil }
        return CPUInfo(
            model: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown processor",
            architecture: Sysctl.int("hw.optional.arm64") == 1 ? "arm64" : "x86_64",
            physicalCores: Sysctl.int("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            logicalCores: Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            performanceLevels: levels,
            coreClusters: readCoreClusters(),
            l1iCache: Sysctl.int("hw.l1icachesize"),
            l1dCache: Sysctl.int("hw.l1dcachesize"),
            l2Cache: Sysctl.int("hw.l2cachesize"),
            l3Cache: l3,
            bootTime: bootTime
        )
    }

    private static func readCoreClusters() -> [String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var clusters: [(Int, String)] = []
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            guard let type = ioString(IORegistry.property("cluster-type", of: cpu)) else { continue }
            let id = ioInt(IORegistry.property("logical-cpu-id", of: cpu)) ?? clusters.count
            clusters.append((id, type))
        }
        return clusters.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

struct CPUSample {
    var total: Double = 0     // 0...1
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]
}

final class CPUCollector {
    private var previousTicks: [[UInt32]] = []

    func sample() -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return CPUSample() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) })
        }

        var result = CPUSample()
        var userSum = 0.0, systemSum = 0.0, totalSum = 0.0
        if previousTicks.count == ticks.count {
            for (now, before) in zip(ticks, previousTicks) {
                // Counters are 32-bit and wrap; unsigned subtraction handles that.
                let user = Double(now[Int(CPU_STATE_USER)] &- before[Int(CPU_STATE_USER)])
                    + Double(now[Int(CPU_STATE_NICE)] &- before[Int(CPU_STATE_NICE)])
                let system = Double(now[Int(CPU_STATE_SYSTEM)] &- before[Int(CPU_STATE_SYSTEM)])
                let idle = Double(now[Int(CPU_STATE_IDLE)] &- before[Int(CPU_STATE_IDLE)])
                let total = user + system + idle
                result.perCore.append(total > 0 ? (user + system) / total : 0)
                userSum += user
                systemSum += system
                totalSum += total
            }
        } else {
            result.perCore = Array(repeating: 0, count: ticks.count)
        }
        previousTicks = ticks

        if totalSum > 0 {
            result.user = userSum / totalSum
            result.system = systemSum / totalSum
            result.total = result.user + result.system
        }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        result.loadAverage = load
        return result
    }
}
