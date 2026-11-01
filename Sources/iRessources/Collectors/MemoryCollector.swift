// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct MemorySample {
    var total: UInt64 = 0
    var used: UInt64 = 0        // app + wired + compressed, as Activity Monitor counts it
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0       // file-backed + purgeable
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Double = 0     // 0...1, from the kernel's memorystatus level
    var pressureLevel: Int = 1   // 1 normal, 2 warning, 4 critical
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var swapIns: UInt64 = 0
    var swapOuts: UInt64 = 0

    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var swapRatio: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
}

final class MemoryCollector {
    let total = UInt64(Sysctl.int("hw.memsize") ?? 0)

    func sample() -> MemorySample {
        var result = MemorySample(total: total)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(stats.purgeable_count)
            let internalPages = UInt64(stats.internal_page_count)
            result.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            result.wired = UInt64(stats.wire_count) * page
            result.compressed = UInt64(stats.compressor_page_count) * page
            result.cached = (UInt64(stats.external_page_count) + purgeable) * page
            result.used = min(result.app + result.wired + result.compressed, total)
            result.free = total - result.used
            result.pageIns = stats.pageins
            result.pageOuts = stats.pageouts
            result.swapIns = stats.swapins
            result.swapOuts = stats.swapouts
        }

        if let swap = Sysctl.value("vm.swapusage", initial: xsw_usage()) {
            result.swapTotal = swap.xsu_total
            result.swapUsed = swap.xsu_used
        }
        if let level = Sysctl.int("kern.memorystatus_level") {
            result.pressure = Double(100 - level) / 100
        }
        result.pressureLevel = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        return result
    }
}
