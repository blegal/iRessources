// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation

/// Fixed-size history of a metric, newest value last.
struct History: Equatable {
    static let capacity = 60
    /// Starts full of zeros so graphs span their whole width from the first sample, like Resources.
    private(set) var values = [Double](repeating: 0, count: capacity)

    mutating func append(_ value: Double) {
        values.append(value.isFinite ? value : 0)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    var last: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
}

struct AppSample: Identifiable, Hashable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var cpu: Double
    var memory: UInt64
    var diskReadPerSecond: Double
    var diskWritePerSecond: Double
    var gpu: Double
    var processIDs: [pid_t]
    var launchDate: Date?
}

/// Expensive collectors that only run while something on screen needs them.
/// The cheap ones (CPU, memory, GPU, drives, network, battery) always run so
/// that the sidebar graphs stay continuous.
struct Demand: OptionSet, Sendable {
    let rawValue: Int
    static let processes = Demand(rawValue: 1 << 0)   // process list, per-process GPU
    static let power = Demand(rawValue: 1 << 1)       // IOReport energy and frequencies
    static let sensors = Demand(rawValue: 1 << 2)     // HID temperature sensors
}

/// Everything gathered during one refresh, produced off the main thread.
private struct Snapshot {
    var cpu: CPUSample
    var power: PowerSample?
    var memory: MemorySample
    var gpus: [GPUSample]
    var drives: [DriveSample]
    var networks: [NetworkSample]
    var battery: BatterySample?
    var temperatures: TemperatureSample?
    var processes: [ProcessSample]?
}

@MainActor
@Observable
final class SystemMonitor {
    let cpuInfo = CPUInfo.read()
    let hasPowerMetrics: Bool

    private(set) var cpu = CPUSample()
    private(set) var cpuHistory = History()
    private(set) var cpuUserHistory = History()
    private(set) var cpuSystemHistory = History()
    private(set) var coreHistories: [History] = []

    private(set) var power = PowerSample()
    private(set) var cpuPowerHistory = History()
    private(set) var gpuPowerHistory = History()
    private(set) var anePowerHistory = History()

    private(set) var memory = MemorySample()
    private(set) var memoryHistory = History()
    private(set) var swapHistory = History()

    private(set) var gpus: [GPUSample] = []
    private(set) var gpuHistories: [UInt64: History] = [:]
    private(set) var gpuMemoryHistories: [UInt64: History] = [:]
    private(set) var gpuFrequencyHistory = History()

    private(set) var drives: [DriveSample] = []
    private(set) var driveReadHistories: [UInt64: History] = [:]
    private(set) var driveWriteHistories: [UInt64: History] = [:]
    private(set) var driveActiveHistories: [UInt64: History] = [:]

    private(set) var networks: [NetworkSample] = []
    private(set) var networkReceiveHistories: [String: History] = [:]
    private(set) var networkSendHistories: [String: History] = [:]

    private(set) var battery: BatterySample?
    private(set) var batteryChargeHistory = History()
    private(set) var batteryPowerHistory = History()

    private(set) var temperatures = TemperatureSample()
    private(set) var socTemperatureHistory = History()

    private(set) var processes: [ProcessSample] = []
    private(set) var apps: [AppSample] = []
    private(set) var lastUpdate = Date()

    var refreshInterval: TimeInterval {
        didSet { sampler.setInterval(effectiveInterval) }
    }

    /// What the visible page needs, set by the views.
    var demand: Demand = [] {
        didSet { if demand != oldValue { updateSampler() } }
    }

    /// False when no window is on screen; sampling then slows down and drops expensive collectors.
    var isVisible = true {
        didSet { if isVisible != oldValue { updateSampler() } }
    }

    private var effectiveInterval: TimeInterval { isVisible ? refreshInterval : max(refreshInterval, 5) }

    @ObservationIgnored private let sampler: Sampler

    init() {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = stored > 0 ? stored : 2
        sampler = Sampler()
        hasPowerMetrics = sampler.hasPowerMetrics
        sampler.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        sampler.start(interval: refreshInterval)
    }

    private func updateSampler() {
        sampler.setDemand(isVisible ? demand : [])
        sampler.setInterval(effectiveInterval)
        // Get fresh data immediately when a page that needs more appears.
        if isVisible { sampler.fire() }
    }

    func process(_ pid: pid_t) -> ProcessSample? { processes.first { $0.pid == pid } }

    func refreshNow() { sampler.fire() }

    // MARK: - Applying a snapshot

    private func apply(_ snapshot: Snapshot) {
        lastUpdate = Date()

        cpu = snapshot.cpu
        cpuHistory.append(cpu.total)
        cpuUserHistory.append(cpu.user)
        cpuSystemHistory.append(cpu.system)
        if coreHistories.count != cpu.perCore.count {
            coreHistories = Array(repeating: History(), count: cpu.perCore.count)
        }
        for (index, value) in cpu.perCore.enumerated() { coreHistories[index].append(value) }

        if let snapshotPower = snapshot.power {
            power = snapshotPower
            if let watts = power.cpuWatts { cpuPowerHistory.append(watts) }
            gpuPowerHistory.append(power.gpuWatts ?? 0)
            anePowerHistory.append(power.aneWatts ?? 0)
            gpuFrequencyHistory.append(power.gpuFrequencyMHz ?? 0)
        }

        memory = snapshot.memory
        memoryHistory.append(memory.usedRatio)
        swapHistory.append(memory.swapRatio)

        gpus = snapshot.gpus
        for gpu in gpus {
            gpuHistories[gpu.id, default: History()].append(gpu.deviceUtilization ?? 0)
            let limit = memory.total
            gpuMemoryHistories[gpu.id, default: History()].append(limit > 0 ? Double(gpu.memoryUsed ?? 0) / Double(limit) : 0)
        }

        drives = snapshot.drives
        for drive in drives {
            driveReadHistories[drive.id, default: History()].append(drive.readBytesPerSecond)
            driveWriteHistories[drive.id, default: History()].append(drive.writeBytesPerSecond)
            driveActiveHistories[drive.id, default: History()].append(drive.activeRatio)
        }

        networks = snapshot.networks
        for network in networks {
            networkReceiveHistories[network.bsdName, default: History()].append(network.receivedBytesPerSecond)
            networkSendHistories[network.bsdName, default: History()].append(network.sentBytesPerSecond)
        }

        battery = snapshot.battery
        if let battery {
            batteryChargeHistory.append(battery.charge)
            batteryPowerHistory.append(abs(battery.watts ?? 0))
        }

        if let snapshotTemperatures = snapshot.temperatures {
            temperatures = snapshotTemperatures
            socTemperatureHistory.append(temperatures.soc ?? 0)
        }

        if let snapshotProcesses = snapshot.processes {
            processes = snapshotProcesses
            apps = groupApplications(snapshotProcesses)
        } else if !processes.isEmpty {
            // Release the process list while nobody looks at it.
            processes = []
            apps = []
        }
    }

    /// Regular apps, rebuilt only when an app launches or quits. Every property
    /// of NSRunningApplication (even its pid) can cost a LaunchServices round
    /// trip, so they must not be read on each refresh.
    private struct RunningApp {
        var pid: pid_t
        var name: String
        var bundleIdentifier: String?
        var bundlePath: String?
        var launchDate: Date?
    }

    @ObservationIgnored private var runningApps: [RunningApp]?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    private func regularApps() -> [RunningApp] {
        if let runningApps { return runningApps }
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.runningApps = nil }
                })
            }
        }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", bundleIdentifier: $0.bundleIdentifier,
                              bundlePath: $0.bundleURL?.path, launchDate: $0.launchDate) }
        runningApps = apps
        return apps
    }

    /// Builds the "Apps" list: regular applications with every process they are responsible for.
    private func groupApplications(_ processes: [ProcessSample]) -> [AppSample] {
        let running = regularApps()
        let appPIDs = Set(running.map(\.pid))

        var children: [pid_t: [ProcessSample]] = [:]
        for process in processes {
            let owner: pid_t
            if appPIDs.contains(process.pid) {
                owner = process.pid
            } else if appPIDs.contains(process.responsiblePID) {
                owner = process.responsiblePID
            } else if appPIDs.contains(process.parentPID) {
                owner = process.parentPID
            } else {
                continue
            }
            children[owner, default: []].append(process)
        }

        return running.compactMap { app in
            guard let members = children[app.pid], !members.isEmpty else { return nil }
            return AppSample(
                pid: app.pid,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundlePath,
                cpu: members.reduce(0) { $0 + $1.cpu },
                memory: members.reduce(0) { $0 + $1.memory },
                diskReadPerSecond: members.reduce(0) { $0 + $1.diskReadPerSecond },
                diskWritePerSecond: members.reduce(0) { $0 + $1.diskWritePerSecond },
                gpu: min(members.reduce(0) { $0 + $1.gpu }, 1),
                processIDs: members.map(\.pid),
                launchDate: app.launchDate
            )
        }
    }
}

/// Owns every collector and runs them on a private serial queue.
private final class Sampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "iRessources.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let cpu = CPUCollector()
    private let power = PowerCollector()
    private let memory = MemoryCollector()
    private let gpu = GPUCollector()
    private let drive = DriveCollector()
    private let network = NetworkCollector()
    private let battery = BatteryCollector()
    private let sensors = SensorCollector()
    private let process = ProcessCollector()

    var onSnapshot: ((Snapshot) -> Void)?
    var hasPowerMetrics: Bool { power.isAvailable }
    private var demand: Demand = []

    func setDemand(_ demand: Demand) {
        queue.async { self.demand = demand }
    }

    func start(interval: TimeInterval) {
        queue.async {
            // Prime the delta-based collectors so the first visible sample is meaningful.
            _ = self.collect()
        }
        setInterval(interval)
    }

    func setInterval(_ interval: TimeInterval) {
        queue.async {
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let snapshot = self.collect()
                self.onSnapshot?(snapshot)
            }
            timer.resume()
            self.timer = timer
        }
    }

    func fire() {
        queue.async {
            let snapshot = self.collect()
            self.onSnapshot?(snapshot)
        }
    }

    private func collect() -> Snapshot {
        autoreleasepool {
            let wantsProcesses = demand.contains(.processes)
            let gpuUsage = wantsProcesses ? gpu.processUsage() : [:]
            return Snapshot(
                cpu: cpu.sample(),
                power: demand.contains(.power) ? power.sample() : nil,
                memory: memory.sample(),
                gpus: gpu.sample(),
                drives: drive.sample(),
                networks: network.sample(),
                battery: battery.sample(),
                temperatures: demand.contains(.sensors) ? sensors.sample() : nil,
                processes: wantsProcesses ? process.sample(gpuUsage: gpuUsage) : nil
            )
        }
    }
}
