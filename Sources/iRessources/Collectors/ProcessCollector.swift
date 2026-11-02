// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import CSystem
import Darwin
import Foundation

struct ProcessSample: Identifiable, Hashable {
    var id: pid_t { pid }
    var pid: pid_t
    var parentPID: pid_t
    var responsiblePID: pid_t
    var uid: uid_t
    var user: String
    var name: String
    var executablePath: String?
    var state: State
    var startTime: Date?
    /// CPU usage in "cores": 1.0 means one logical core fully busy.
    var cpu: Double = 0
    var cpuTime: TimeInterval = 0
    var memory: UInt64 = 0
    var threads: Int = 0
    var diskReadPerSecond: Double = 0
    var diskWritePerSecond: Double = 0
    var totalDiskRead: UInt64 = 0
    var totalDiskWritten: UInt64 = 0
    var gpu: Double = 0
    var priority: Int32 = 0
    /// False when the kernel refused detailed statistics (another user's process).
    var isAccessible = true

    enum State: String {
        case running = "Running", sleeping = "Sleeping", stopped = "Stopped", zombie = "Zombie", idle = "Idle", unknown = "Unknown"
    }
}

final class ProcessCollector {
    private struct Previous { var startTime: UInt64; var cpuNanoseconds: UInt64; var diskRead: UInt64; var diskWritten: UInt64 }
    private var previous: [pid_t: Previous] = [:]
    private var previousTime = Date()
    private var userNames: [uid_t: String] = [:]
    private var pathCache: [pid_t: (start: UInt64, path: String?)] = [:]
    private var responsibleCache: [pid_t: (start: UInt64, owner: pid_t)] = [:]

    func sample(gpuUsage: [pid_t: Double]) -> [ProcessSample] {
        let now = Date()
        let elapsedNs = max(now.timeIntervalSince(previousTime), 0.001) * 1e9

        let pids = Self.allPIDs()
        var result: [ProcessSample] = []
        result.reserveCapacity(pids.count)
        var next: [pid_t: Previous] = [:]

        for pid in pids {
            guard let (basic, task) = basicInfo(pid: pid) else { continue }
            var process = basic
            let startKey = UInt64(process.startTime?.timeIntervalSince1970 ?? 0)
            process.responsiblePID = responsiblePID(pid: pid, start: startKey)

            if let task {
                process.threads = Int(task.pti_threadnum)
                process.memory = task.pti_resident_size
                process.priority = task.pti_priority
            } else {
                process.isAccessible = false
            }

            var usage = rusage_info_v4()
            let usageStatus = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if usageStatus == 0 {
                // Footprint matches the "Memory" column of Activity Monitor.
                process.memory = usage.ri_phys_footprint
                let cpuNs = UInt64(Double(usage.ri_user_time + usage.ri_system_time) * MachTime.nanosecondsPerTick)
                process.cpuTime = Double(cpuNs) / 1e9
                process.totalDiskRead = usage.ri_diskio_bytesread
                process.totalDiskWritten = usage.ri_diskio_byteswritten

                if let before = previous[pid], before.startTime == startKey {
                    process.cpu = Double(cpuNs &- before.cpuNanoseconds) / elapsedNs
                    let seconds = elapsedNs / 1e9
                    process.diskReadPerSecond = Double(usage.ri_diskio_bytesread &- before.diskRead) / seconds
                    process.diskWritePerSecond = Double(usage.ri_diskio_byteswritten &- before.diskWritten) / seconds
                }
                next[pid] = Previous(startTime: startKey, cpuNanoseconds: cpuNs,
                                     diskRead: usage.ri_diskio_bytesread, diskWritten: usage.ri_diskio_byteswritten)
            } else {
                process.isAccessible = false
            }

            process.gpu = gpuUsage[pid] ?? 0
            process.executablePath = path(for: pid, start: startKey)
            if let path = process.executablePath, process.name.count >= 15 {
                // pbi_name is truncated; the executable name is usually more complete.
                process.name = (path as NSString).lastPathComponent
            }
            result.append(process)
        }

        previous = next
        previousTime = now
        let alive = Set(pids)
        pathCache = pathCache.filter { alive.contains($0.key) }
        responsibleCache = responsibleCache.filter { alive.contains($0.key) }
        return result
    }

    // MARK: - Helpers

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    /// BSD and task information. A single PROC_PIDTASKALLINFO call covers both
    /// for our own processes; others fall back to the BSD-only flavours.
    private func basicInfo(pid: pid_t) -> (ProcessSample, proc_taskinfo?)? {
        var all = proc_taskallinfo()
        let allSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, allSize) == allSize {
            return (sample(from: all.pbsd, pid: pid), all.ptinfo)
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return (sample(from: info, pid: pid), nil)
        }
        // Fallback for processes whose full BSD info is restricted.
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { return nil }
        let comm = withUnsafeBytes(of: short.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return (ProcessSample(
            pid: pid, parentPID: pid_t(short.pbsi_ppid), responsiblePID: pid, uid: short.pbsi_uid,
            user: userName(short.pbsi_uid), name: comm, state: Self.state(short.pbsi_status), startTime: nil
        ), nil)
    }

    private func responsiblePID(pid: pid_t, start: UInt64) -> pid_t {
        if let cached = responsibleCache[pid], cached.start == start { return cached.owner }
        let owner = responsibility_get_pid_responsible_for_pid(pid)
        responsibleCache[pid] = (start, owner)
        return owner
    }

    private func sample(from info: proc_bsdinfo, pid: pid_t) -> ProcessSample {
        let name = withUnsafeBytes(of: info.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let comm = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return ProcessSample(
            pid: pid,
            parentPID: pid_t(info.pbi_ppid),
            responsiblePID: pid,
            uid: info.pbi_uid,
            user: userName(info.pbi_uid),
            name: name.isEmpty ? comm : name,
            state: Self.state(info.pbi_status),
            startTime: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        )
    }

    private func path(for pid: pid_t, start: UInt64) -> String? {
        if let cached = pathCache[pid], cached.start == start { return cached.path }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil
        pathCache[pid] = (start, path)
        return path
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userNames[uid] = name
        return name
    }

    private static func state(_ status: UInt32) -> ProcessSample.State {
        switch Int32(status) {
        case SRUN: .running
        case SSLEEP: .sleeping
        case SSTOP: .stopped
        case SZOMB: .zombie
        case SIDL: .idle
        default: .unknown
        }
    }

    // MARK: - Details on demand

    /// Full command line, read through KERN_PROCARGS2.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and its padding.
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    enum Signal {
        case terminate, kill, stop, resume

        var number: Int32 {
            switch self {
            case .terminate: SIGTERM
            case .kill: SIGKILL
            case .stop: SIGSTOP
            case .resume: SIGCONT
            }
        }
    }

    /// True when the process is suspended (SIGSTOP).
    static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == SSTOP
    }

    /// Sends a signal; returns an error message on failure.
    @discardableResult
    static func send(_ signal: Signal, to pid: pid_t) -> String? {
        guard Darwin.kill(pid, signal.number) != 0 else { return nil }
        return String(cString: strerror(errno))
    }
}
