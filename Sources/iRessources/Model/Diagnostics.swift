// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `iRessources --dump` prints one sample of every collector and exits.
/// Handy to check what a given Mac exposes without opening the UI.
enum Diagnostics {
    static func dump() {
        let cpu = CPUCollector(), power = PowerCollector(), gpu = GPUCollector(), drives = DriveCollector()
        let network = NetworkCollector(), processes = ProcessCollector()
        _ = cpu.sample(); _ = power.sample(); _ = gpu.processUsage(); _ = drives.sample(); _ = network.sample()
        _ = processes.sample(gpuUsage: [:])
        Thread.sleep(forTimeInterval: 1)

        let info = CPUInfo.read()
        print("CPU      \(info.model) — \(info.physicalCores)C/\(info.logicalCores)T clusters=\(info.coreClusters.joined())")
        print("         levels: \(info.performanceLevels.map { "\($0.name)×\($0.logicalCPUs)" }.joined(separator: ", "))")
        let c = cpu.sample()
        print("         total \(Format.percent(c.total)) user \(Format.percent(c.user)) system \(Format.percent(c.system))")
        print("         per core: " + zip(info.coreClusters + Array(repeating: "?", count: max(c.perCore.count - info.coreClusters.count, 0)), c.perCore)
            .map { "\($0.0)\(Int($0.1 * 100))" }.joined(separator: " "))

        let p = power.sample()
        print("Power    available=\(power.isAvailable) CPU \(Format.watts(p.cpuWatts)) GPU \(Format.watts(p.gpuWatts)) "
              + "ANE \(Format.watts(p.aneWatts)) DRAM \(Format.watts(p.dramWatts))")
        for cluster in p.clusters {
            print("         \(cluster.name): \(Format.megahertz(cluster.frequencyMHz)) active \(Format.percent(cluster.activeRatio))")
        }
        print("         GPU \(Format.megahertz(p.gpuFrequencyMHz)) active \(Format.percent(p.gpuActiveRatio ?? 0))")

        let m = MemoryCollector().sample()
        print("Memory   used \(Format.bytes(m.used)) / \(Format.bytes(m.total)) app \(Format.bytes(m.app)) wired \(Format.bytes(m.wired)) "
              + "compressed \(Format.bytes(m.compressed)) cached \(Format.bytes(m.cached)) swap \(Format.bytes(m.swapUsed)) pressure \(Format.percent(m.pressure))")

        for g in gpu.sample() {
            print("GPU      \(g.name) [\(g.vendor)] cores=\(g.cores.map(String.init) ?? "?") usage \(Format.percent(g.deviceUtilization ?? 0)) "
                  + "mem \(Format.bytes(g.memoryUsed ?? 0)) unified=\(g.hasUnifiedMemory)")
        }
        let gpuUsage = gpu.processUsage()

        for d in drives.sample() {
            print("Drive    \(d.bsdName) \(d.model) [\(d.kind), \(d.interconnect ?? "?"), internal=\(d.isInternal)] \(Format.storage(d.capacity)) "
                  + "R \(Format.rate(d.readBytesPerSecond)) W \(Format.rate(d.writeBytesPerSecond))")
            for v in d.volumes { print("           \(v.name) \(v.mountPoint) \(Format.storage(v.used))/\(Format.storage(v.total))") }
        }
        for n in network.sample() {
            print("Network  \(n.bsdName) \(n.displayName) [\(n.kind.rawValue)] up=\(n.isUp) ipv4=\(n.ipv4) "
                  + "↓ \(Format.rate(n.receivedBytesPerSecond)) ↑ \(Format.rate(n.sentBytesPerSecond))"
                  + (n.wifi.map { " rssi=\($0.rssi) rate=\($0.transmitRateMbps)" } ?? ""))
        }
        if let b = BatteryCollector().sample() {
            print("Battery  \(Format.percent(b.charge)) charging=\(b.isCharging) health=\(b.health.map { Format.percent($0) } ?? "?") "
                  + "cycles=\(b.cycleCount ?? -1) \(Format.watts(b.watts)) \(Format.celsius(b.temperature))")
        }
        let t = SensorCollector().sample()
        print("Sensors  \(t.sensors.count) sensors, SoC \(Format.celsius(t.soc)) NAND \(Format.celsius(t.storage)) battery \(Format.celsius(t.battery))")

        let list = processes.sample(gpuUsage: gpuUsage)
        let accessible = list.filter(\.isAccessible).count
        print("Processes \(list.count) (\(accessible) with full statistics)")
        for proc in list.sorted(by: { $0.cpu > $1.cpu }).prefix(8) {
            print("         \(proc.pid) \(proc.name) cpu \(Format.percent(proc.cpu, decimals: 1)) mem \(Format.bytes(proc.memory)) "
                  + "gpu \(Format.percent(proc.gpu, decimals: 1)) resp \(proc.responsiblePID) user \(proc.user)")
        }
    }
}

import AppKit

extension Diagnostics {
    /// When IRESSOURCES_SNAPSHOTS points to a directory, visits every page and
    /// saves a PNG of the window for each, then quits. Used to check the UI
    /// without screen-recording permission.
    static var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["IRESSOURCES_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
    }

    @MainActor static var snapshotStarted = false

    @MainActor
    static func snapshotPages(_ pages: [(String, SidebarPage)], select: (SidebarPage) -> Void) async {
        guard let directory = snapshotDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, page) in pages {
            select(page)
            try? await Task.sleep(for: .seconds(5))
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        NSApp.terminate(nil)
    }
}
