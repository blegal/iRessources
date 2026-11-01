// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// "8.37 MB/s · Highest: 247.76 MB/s", as Resources labels its throughput graphs.
private func rateWithPeak(_ current: Double, _ history: History?) -> String {
    "\(Format.rate(current)) · Highest: \(Format.rate(history?.peak ?? current))"
}

// MARK: - Processor

struct CPUPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    @AppStorage("cpuShowCores") private var showCores = true

    var body: some View {
        let info = monitor.cpuInfo
        let cpu = monitor.cpu
        // With the per-core grid shown, the page grows with the window so more cores fit per row.
        Page(title: info.model, subtitle: "Processor", maxWidth: showCores ? 1600 : 680) {
            PageSection(title: "Options") {
                BoxedList {
                    ToggleRow(title: "Show usage of logical CPUs", isOn: $showCores)
                }
            }

            PageSection(title: "Usage") {
                if showCores {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 10)], spacing: 10) {
                        ForEach(monitor.coreHistories.indices, id: \.self) { index in
                            BoxedList {
                                VStack(alignment: .leading, spacing: 6) {
                                    GraphView(monitor.coreHistories[index].values, color: theme.cpu)
                                        .frame(height: 64)
                                    Text(coreLabel(index)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    AnimatedText(Format.percent(cpu.perCore[safe: index] ?? 0))
                                }
                                .padding(10)
                            }
                        }
                    }
                }
                BoxedList {
                    GraphRow(label: "Total usage",
                             value: "\(Format.percent(cpu.total)) · System \(Format.percent(cpu.system)) · User \(Format.percent(cpu.user))",
                             graph: GraphView(series: [.init(values: monitor.cpuHistory.values, color: theme.cpu),
                                                       .init(values: monitor.cpuSystemHistory.values, color: theme.gpu)],
                                              maximum: 1),
                             height: showCores ? 90 : 160)
                    if monitor.power.cpuWatts != nil {
                        GraphRow(label: "Power usage",
                                 value: "\(Format.watts(monitor.power.cpuWatts)) · Highest: \(Format.watts(monitor.cpuPowerHistory.peak))",
                                 graph: GraphView(monitor.cpuPowerHistory.values, color: theme.power, maximum: nil, minimumScale: 2),
                                 height: 80)
                    }
                    ForEach(monitor.power.clusters, id: \.name) { cluster in
                        PropertyRow("\(clusterName(cluster.name)) cluster",
                                    "\(Format.megahertz(cluster.frequencyMHz)) · \(Format.percent(cluster.activeRatio)) active")
                    }
                }
            }

            PageSection(title: "Properties") {
                BoxedList {
                    ForEach(properties(info), id: \.0) { PropertyRow($0.0, $0.1) }
                }
            }
        }
    }

    private func coreLabel(_ index: Int) -> String {
        guard let type = monitor.cpuInfo.coreClusters[safe: index] else { return "CPU \(index + 1)" }
        return "CPU \(index + 1) · \(coreType(type))"
    }

    /// Names an IOReport cluster ("PCPU", "MCPU1"…) after the matching macOS performance level.
    private func clusterName(_ name: String) -> String {
        let letter = name.first.map(String.init) ?? ""
        let suffix = name.drop { !$0.isNumber }
        return [coreType(letter), suffix.isEmpty ? nil : String(suffix)].compactMap { $0 }.joined(separator: " ")
    }

    private func coreType(_ letter: String) -> String {
        let cores = monitor.cpuInfo.coreClusters.filter { $0 == letter }.count
        return monitor.cpuInfo.performanceLevels.first { $0.logicalCPUs == cores }?.name ?? letter
    }

    private func properties(_ info: CPUInfo) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Model", info.model),
            ("Architecture", info.architecture),
            ("Cores", "\(info.physicalCores) physical, \(info.logicalCores) logical"),
        ]
        for level in info.performanceLevels {
            rows.append(("\(level.name) cores", "\(level.logicalCPUs)" + (level.l2Cache.map { " · L2 cache \(Format.bytes($0))" } ?? "")))
        }
        rows.append(("L1 cache", "\(Format.bytes(info.l1iCache)) instruction · \(Format.bytes(info.l1dCache)) data"))
        if info.performanceLevels.isEmpty { rows.append(("L2 cache", Format.bytes(info.l2Cache))) }
        if let l3 = info.l3Cache { rows.append(("L3 cache", Format.bytes(l3))) }
        rows.append(("Load average", monitor.cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · ")))
        if let soc = monitor.temperatures.soc { rows.append(("Temperature", Format.celsius(soc))) }
        rows.append(("Thermal state", thermalState))
        if let boot = info.bootTime { rows.append(("Uptime", Format.duration(Date().timeIntervalSince(boot)))) }
        return rows
    }

    private var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious — throttling"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

// MARK: - Memory

struct MemoryPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme

    var body: some View {
        let memory = monitor.memory
        Page(title: "Memory", subtitle: "\(Format.bytes(memory.total)) unified memory") {
            PageSection(title: "Usage") {
                BoxedList {
                    GraphRow(label: "Memory",
                             value: "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total)) · \(Format.percent(memory.usedRatio))",
                             graph: GraphView(monitor.memoryHistory.values, color: theme.memory))
                    GraphRow(label: "Swap",
                             value: memory.swapTotal > 0
                                ? "\(Format.bytes(memory.swapUsed)) / \(Format.bytes(memory.swapTotal)) · \(Format.percent(memory.swapRatio))"
                                : "Not in use",
                             graph: GraphView(monitor.swapHistory.values, color: theme.swap))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Breakdown").font(.caption).foregroundStyle(.secondary)
                        breakdown(memory)
                    }
                    .padding(14)
                }
            }

            PageSection(title: "Properties") {
                BoxedList {
                    PropertyRow("Total", Format.bytes(memory.total))
                    PropertyRow("Available", Format.bytes(memory.free + memory.cached))
                    PropertyRow("Memory pressure", "\(pressureLabel(memory.pressureLevel)) · \(Format.percent(memory.pressure))")
                    PropertyRow("Page-ins / page-outs", "\(memory.pageIns.formatted()) / \(memory.pageOuts.formatted())")
                    PropertyRow("Swap-ins / swap-outs", "\(memory.swapIns.formatted()) / \(memory.swapOuts.formatted())")
                }
            }
        }
    }

    private func breakdown(_ memory: MemorySample) -> some View {
        let parts: [(String, UInt64, Color)] = [
            ("App memory", memory.app, theme.memory),
            ("Wired", memory.wired, theme.drive),
            ("Compressed", memory.compressed, theme.power),
            ("Cached files", memory.cached, theme.network),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            // Stacked bar of the whole memory.
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(part.2)
                            .frame(width: max(proxy.size.width * CGFloat(part.1) / CGFloat(max(memory.total, 1)) - 2, 0))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 12)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        Text(part.0).foregroundStyle(.secondary)
                        AnimatedText(Format.bytes(part.1))
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func pressureLabel(_ level: Int) -> String {
        level >= 4 ? "Critical" : level >= 2 ? "Warning" : "Normal"
    }
}

// MARK: - GPU

struct GPUPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    var id: UInt64

    var body: some View {
        if let gpu = monitor.gpus.first(where: { $0.id == id }) {
            Page(title: gpu.name, subtitle: "GPU") {
                PageSection(title: "Usage") {
                    BoxedList {
                        GraphRow(label: "Total usage", value: gpu.deviceUtilization.map { Format.percent($0) } ?? "—",
                                 graph: GraphView(monitor.gpuHistories[id]?.values ?? [], color: theme.gpu))
                        HStack(spacing: 0) {
                            PropertyRow("Renderer", gpu.rendererUtilization.map { Format.percent($0) } ?? "—")
                            PropertyRow("Tiler", gpu.tilerUtilization.map { Format.percent($0) } ?? "—")
                            if let frequency = monitor.power.gpuFrequencyMHz {
                                PropertyRow("Frequency", Format.megahertz(frequency))
                            }
                        }
                        GraphRow(label: gpu.hasUnifiedMemory ? "Memory in use (shared)" : "Video memory",
                                 value: Format.bytes(gpu.memoryUsed ?? 0),
                                 graph: GraphView(monitor.gpuMemoryHistories[id]?.values ?? [], color: theme.gpu,
                                                  maximum: nil, minimumScale: 0.01),
                                 height: 80)
                        if monitor.hasPowerMetrics {
                            GraphRow(label: "Power usage",
                                     value: "\(Format.watts(monitor.power.gpuWatts)) · Highest: \(Format.watts(monitor.gpuPowerHistory.peak))",
                                     graph: GraphView(monitor.gpuPowerHistory.values, color: theme.power, maximum: nil, minimumScale: 2),
                                     height: 80)
                        }
                    }
                }

                PageSection(title: "Properties") {
                    BoxedList {
                        PropertyRow("Model", gpu.name)
                        PropertyRow("Vendor", gpu.vendor)
                        if let cores = gpu.cores { PropertyRow("GPU cores", "\(cores)") }
                        PropertyRow("Memory", gpu.hasUnifiedMemory ? "Unified, shared with the CPU" : "Dedicated")
                        if let alloc = gpu.memoryAllocated { PropertyRow("Allocated memory", Format.bytes(alloc)) }
                        if let soc = monitor.temperatures.soc { PropertyRow("SoC temperature", Format.celsius(soc)) }
                    }
                }
            }
        } else {
            ContentUnavailableView("GPU unavailable", systemImage: "cube.transparent")
        }
    }
}

// MARK: - Neural Engine

struct NPUPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme

    var body: some View {
        Page(title: "Apple Neural Engine", subtitle: "NPU") {
            PageSection(title: "Usage") {
                BoxedList {
                    GraphRow(label: "Power usage",
                             value: monitor.power.aneWatts.map { "\(Format.watts($0)) · Highest: \(Format.watts(monitor.anePowerHistory.peak))" } ?? "Idle",
                             graph: GraphView(monitor.anePowerHistory.values, color: theme.npu, maximum: nil, minimumScale: 1))
                }
                Label("macOS does not publish a utilisation percentage for the Neural Engine. Its power draw, "
                      + "read from IOReport, is the most reliable indicator of activity.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Drives

struct DrivePage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    var id: UInt64

    var body: some View {
        if let drive = monitor.drives.first(where: { $0.id == id }) {
            Page(title: drive.model, subtitle: "\(Format.storage(drive.capacity)) \(drive.kind)") {
                PageSection(title: "Usage") {
                    BoxedList {
                        GraphRow(label: "Drive activity", value: Format.percent(drive.activeRatio),
                                 graph: GraphView(monitor.driveActiveHistories[id]?.values ?? [], color: theme.drive))
                        GraphRow(label: "Read speed", value: rateWithPeak(drive.readBytesPerSecond, monitor.driveReadHistories[id]),
                                 graph: GraphView(monitor.driveReadHistories[id]?.values ?? [], color: theme.drive,
                                                  maximum: nil, minimumScale: 1_000_000))
                        GraphRow(label: "Write speed", value: rateWithPeak(drive.writeBytesPerSecond, monitor.driveWriteHistories[id]),
                                 graph: GraphView(monitor.driveWriteHistories[id]?.values ?? [], color: theme.drive,
                                                  maximum: nil, minimumScale: 1_000_000))
                        PropertyRow("Total read", Format.storage(drive.totalRead))
                        PropertyRow("Total written", Format.storage(drive.totalWritten))
                    }
                }

                if !drive.volumes.isEmpty {
                    PageSection(title: "Volumes") {
                        BoxedList {
                            ForEach(drive.volumes) { volume in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(volume.name)
                                        Text(volume.fileSystem.uppercased()).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(Format.storage(volume.used)) / \(Format.storage(volume.total))")
                                            .monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    UsageBar(ratio: volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0, color: theme.drive)
                                }
                                .padding(14)
                            }
                        }
                    }
                }

                PageSection(title: "Properties") {
                    BoxedList {
                        PropertyRow("Model", drive.model)
                        PropertyRow("Type", drive.kind)
                        PropertyRow("Device", "/dev/\(drive.bsdName)")
                        PropertyRow("Capacity", Format.storage(drive.capacity))
                        if let interconnect = drive.interconnect { PropertyRow("Interface", interconnect) }
                        PropertyRow("Location", drive.isInternal ? "Internal" : "External")
                        PropertyRow("Removable", drive.isRemovable ? "Yes" : "No")
                        if drive.isInternal, let nand = monitor.temperatures.storage {
                            PropertyRow("Temperature", Format.celsius(nand))
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Drive disconnected", systemImage: "externaldrive.badge.xmark")
        }
    }
}

// MARK: - Network

struct NetworkPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    var bsdName: String

    var body: some View {
        if let network = monitor.networks.first(where: { $0.bsdName == bsdName }) {
            Page(title: network.displayName, subtitle: "\(network.kind.rawValue) · \(network.bsdName)") {
                PageSection(title: "Usage") {
                    BoxedList {
                        GraphRow(label: "Receiving",
                                 value: rateWithPeak(network.receivedBytesPerSecond, monitor.networkReceiveHistories[bsdName]),
                                 graph: GraphView(monitor.networkReceiveHistories[bsdName]?.values ?? [], color: theme.network,
                                                  maximum: nil, minimumScale: 10_000))
                        GraphRow(label: "Sending",
                                 value: rateWithPeak(network.sentBytesPerSecond, monitor.networkSendHistories[bsdName]),
                                 graph: GraphView(monitor.networkSendHistories[bsdName]?.values ?? [], color: theme.networkSend,
                                                  maximum: nil, minimumScale: 10_000))
                        PropertyRow("Total received", Format.storage(network.totalReceived))
                        PropertyRow("Total sent", Format.storage(network.totalSent))
                    }
                }

                PageSection(title: "Properties") {
                    BoxedList {
                        PropertyRow("Interface", network.bsdName)
                        PropertyRow("Type", network.kind.rawValue)
                        PropertyRow("State", network.isUp ? "Connected" : "Disconnected")
                        if let wifi = network.wifi {
                            if let ssid = wifi.ssid { PropertyRow("Network", ssid) }
                            PropertyRow("Signal", "\(wifi.rssi) dBm · noise \(wifi.noise) dBm")
                            PropertyRow("Link speed", "\(Int(wifi.transmitRateMbps)) Mbit/s")
                            if let channel = wifi.channel { PropertyRow("Channel", channel) }
                            if let phy = wifi.phyMode { PropertyRow("Standard", phy) }
                        } else if network.linkSpeedBitsPerSecond > 0 {
                            PropertyRow("Link speed", Format.bits(network.linkSpeedBitsPerSecond))
                        }
                        if let mac = network.macAddress { PropertyRow("Hardware address", mac) }
                        if !network.ipv4.isEmpty { PropertyRow("IPv4 address", network.ipv4.joined(separator: ", ")) }
                        if !network.ipv6.isEmpty { PropertyRow("IPv6 address", network.ipv6.joined(separator: "\n")) }
                        PropertyRow("MTU", "\(network.mtu)")
                    }
                }
            }
        } else {
            ContentUnavailableView("Interface unavailable", systemImage: "network.slash")
        }
    }
}

// MARK: - Battery

struct BatteryPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme

    var body: some View {
        if let battery = monitor.battery {
            Page(title: battery.model ?? "Internal battery", subtitle: subtitle(battery)) {
                PageSection(title: "Usage") {
                    BoxedList {
                        GraphRow(label: "Battery charge", value: "\(Format.percent(battery.charge)) (\(status(battery)))",
                                 graph: GraphView(monitor.batteryChargeHistory.values, color: theme.battery))
                        GraphRow(label: battery.isCharging ? "Charging power" : "Power usage",
                                 value: "\(Format.watts(battery.watts.map(abs))) · Highest: \(Format.watts(monitor.batteryPowerHistory.peak))",
                                 graph: GraphView(monitor.batteryPowerHistory.values, color: theme.battery, maximum: nil, minimumScale: 5))
                    }
                }
                PageSection(title: "Properties") {
                    BoxedList {
                        if let health = battery.health { PropertyRow("Battery health", Format.percent(health)) }
                        if let condition = battery.condition { PropertyRow("Condition", condition) }
                        if let design = battery.designCapacity { PropertyRow("Design capacity", "\(design) mAh") }
                        if let max = battery.maxCapacity { PropertyRow("Full charge capacity", "\(max) mAh") }
                        if let cycles = battery.cycleCount { PropertyRow("Charge cycles", "\(cycles)") }
                        if let voltage = battery.voltage { PropertyRow("Voltage", String(format: "%.2f V", voltage)) }
                        if let amperage = battery.amperage { PropertyRow("Current", String(format: "%.2f A", amperage)) }
                        if let temperature = battery.temperature ?? monitor.temperatures.battery {
                            PropertyRow("Temperature", Format.celsius(temperature))
                        }
                        if let watts = battery.adapterWatts {
                            PropertyRow("Power adapter", "\(watts) W" + (battery.adapterName.map { " · \($0)" } ?? ""))
                        }
                        if let manufacturer = battery.manufacturer { PropertyRow("Manufacturer", manufacturer) }
                    }
                }
            }
        } else {
            ContentUnavailableView("No battery", systemImage: "battery.0percent")
        }
    }

    private func subtitle(_ battery: BatterySample) -> String {
        guard let design = battery.designCapacity, let voltage = battery.voltage else { return "Battery" }
        return String(format: "%.0f Wh Battery", Double(design) * voltage / 1000)
    }

    private func status(_ battery: BatterySample) -> String {
        if battery.isFullyCharged { return "Fully charged" }
        if battery.isCharging { return "Charging" + (battery.minutesToFull.map { ", \(Format.minutes($0)) until full" } ?? "") }
        if battery.isPluggedIn { return "Not charging" }
        return "Discharging" + (battery.minutesToEmpty.map { ", \(Format.minutes($0)) left" } ?? "")
    }
}
