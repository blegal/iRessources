// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

enum SidebarPage: Hashable {
    case apps, processes, cpu, memory, gpu(UInt64), npu, drive(UInt64), network(String), battery

    /// The expensive collectors this page relies on.
    var demand: Demand {
        switch self {
        case .apps, .processes: .processes
        case .cpu, .gpu: [.power, .sensors]
        case .npu: .power
        case .drive, .battery: .sensors
        case .memory, .network: []
        }
    }

    /// Sidebar order, used for keyboard navigation.
    @MainActor
    static func order(in monitor: SystemMonitor) -> [SidebarPage] {
        var pages: [SidebarPage] = [.apps, .processes, .cpu, .memory]
        pages += monitor.gpus.map { .gpu($0.id) }
        if monitor.hasPowerMetrics { pages.append(.npu) }
        pages += monitor.drives.map { .drive($0.id) }
        pages += monitor.networks.map { .network($0.bsdName) }
        if monitor.battery != nil { pages.append(.battery) }
        return pages
    }
}

struct SidebarSelectionKey: FocusedValueKey {
    typealias Value = Binding<SidebarPage>
}

extension FocusedValues {
    var sidebarSelection: Binding<SidebarPage>? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

/// View menu items to move through the sidebar from anywhere in the window,
/// including while a table has keyboard focus.
struct SidebarCommands: Commands {
    var monitor: SystemMonitor
    @FocusedBinding(\.sidebarSelection) private var selection

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Previous Resource") { move(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(selection == nil)
            Button("Next Resource") { move(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(selection == nil)
            Divider()
        }
    }

    @MainActor
    private func move(by offset: Int) {
        guard let current = selection else { return }
        let pages = SidebarPage.order(in: monitor)
        guard let index = pages.firstIndex(of: current) else { return }
        selection = pages[min(max(index + offset, 0), pages.count - 1)]
    }
}

struct ContentView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.motion) private var motion
    @State private var selection: SidebarPage = .apps

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .id(selection)
                .transition(.opacity)
        }
        .animation(motion.animation(.easeInOut(duration: 0.2)), value: selection)
        .focusedSceneValue(\.sidebarSelection, $selection)
        .onChange(of: selection, initial: true) { _, page in
            monitor.demand = page.demand
        }
        .task {
            guard Diagnostics.snapshotDirectory != nil, !Diagnostics.snapshotStarted else { return }
            Diagnostics.snapshotStarted = true
            // A longer delay fills the graph histories, for README screenshots.
            let delay = ProcessInfo.processInfo.environment["IRESSOURCES_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
            try? await Task.sleep(for: .seconds(delay))
            var pages: [(String, SidebarPage)] = [("apps", .apps), ("processes", .processes), ("cpu", .cpu), ("memory", .memory)]
            pages += monitor.gpus.map { ("gpu", SidebarPage.gpu($0.id)) }
            if monitor.hasPowerMetrics { pages.append(("npu", .npu)) }
            pages += monitor.drives.prefix(1).map { ("drive", SidebarPage.drive($0.id)) }
            pages += monitor.networks.prefix(1).map { ("network", SidebarPage.network($0.bsdName)) }
            if monitor.battery != nil { pages.append(("battery", .battery)) }
            await Diagnostics.snapshotPages(pages) { selection = $0 }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .apps: AppsPage()
        case .processes: ProcessesPage()
        case .cpu: CPUPage()
        case .memory: MemoryPage()
        case .gpu(let id): GPUPage(id: id)
        case .npu: NPUPage()
        case .drive(let id): DrivePage(id: id)
        case .network(let name): NetworkPage(bsdName: name)
        case .battery: BatteryPage()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    @Binding var selection: SidebarPage
    @AppStorage(Preferences.sidebarGraphs) private var showGraphs = true
    @Namespace private var highlight

    var body: some View {
        // Apps and Processes stay fixed above the scrolling device list. As the
        // first rows of a ScrollView they sat in the band under the toolbar
        // where macOS 26 keeps clicks for the scroll view, so they were hard to select.
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                item(.apps, "Apps", "macwindow")
                item(.processes, "Processes", "gearshape.2")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider().padding(.horizontal, 18).opacity(0.6)
            devices
        }
        .background(theme.sidebarBackground)
    }

    private var devices: some View {
        ScrollView {
            VStack(spacing: 2) {
                item(.cpu, "Processor", "cpu", value: Format.percent(monitor.cpu.total)) {
                    GraphView(monitor.cpuHistory.values, color: theme.cpu)
                }
                item(.memory, "Memory", "memorychip", value: Format.percent(monitor.memory.usedRatio)) {
                    GraphView(monitor.memoryHistory.values, color: theme.memory)
                }
                ForEach(monitor.gpus) { gpu in
                    item(.gpu(gpu.id), monitor.gpus.count > 1 ? gpu.name : "GPU", "cube.transparent",
                         value: gpu.deviceUtilization.map { Format.percent($0) }) {
                        GraphView(monitor.gpuHistories[gpu.id]?.values ?? [], color: theme.gpu)
                    }
                }
                if monitor.hasPowerMetrics {
                    item(.npu, "Neural Engine", "brain", value: monitor.power.aneWatts.map(Format.watts)) {
                        GraphView(monitor.anePowerHistory.values, color: theme.npu, maximum: nil)
                    }
                }
                ForEach(monitor.drives) { drive in
                    item(.drive(drive.id), driveTitle(drive), drive.kind == "Disk image" ? "opticaldiscdrive" : "internaldrive",
                         value: Format.percent(drive.activeRatio)) {
                        GraphView(monitor.driveActiveHistories[drive.id]?.values ?? [], color: theme.drive)
                    }
                }
                ForEach(monitor.networks) { network in
                    item(.network(network.bsdName), network.displayName, network.kind.symbol,
                         value: Format.rate(network.receivedBytesPerSecond + network.sentBytesPerSecond)) {
                        GraphView(series: [
                            .init(values: monitor.networkReceiveHistories[network.bsdName]?.values ?? [], color: theme.network),
                            .init(values: monitor.networkSendHistories[network.bsdName]?.values ?? [], color: theme.networkSend),
                        ], minimumScale: 10_000)
                    }
                }
                if let battery = monitor.battery {
                    item(.battery, "Battery", batterySymbol(battery), value: Format.percent(battery.charge)) {
                        GraphView(monitor.batteryChargeHistory.values, color: theme.battery)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    private func item(_ page: SidebarPage, _ title: String, _ symbol: String, value: String? = nil) -> some View {
        item(page, title, symbol, value: value) { EmptyView() }
    }

    private func item<G: View>(_ page: SidebarPage, _ title: String, _ symbol: String, value: String? = nil,
                               @ViewBuilder graph: () -> G) -> some View {
        let isSelected = selection == page
        return Button {
            selection = page
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 4)
                    if let value {
                        AnimatedText(value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if showGraphs && G.self != EmptyView.self {
                    graph().frame(height: 52)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(motion.animation(.spring(response: 0.3, dampingFraction: 0.85)), value: isSelected)
    }

    private func driveTitle(_ drive: DriveSample) -> String {
        if drive.kind == "Disk image" { return drive.volumes.first?.name ?? drive.model }
        return "\(Format.storage(drive.capacity)) \(drive.kind == "SSD" ? "SSD" : "Drive")"
    }

    private func batterySymbol(_ battery: BatterySample) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.charge {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

