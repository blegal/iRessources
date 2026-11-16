// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Shared CPU formatting: either a share of the whole machine or of one core.
private struct CPUText: View {
    @AppStorage("normalizeCPU") private var normalize = true
    var cores: Double
    var logicalCores: Int

    var body: some View {
        let value = normalize ? cores / Double(max(logicalCores, 1)) : cores
        Text(Format.percent(value, decimals: 1))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct TrailingText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Stable rows

/// A table row that stays equal from one refresh to the next while it shows the
/// same process. Under a window toolbar, each update of a SwiftUI `Table` re-adds
/// its header views and AppKit keeps a few dependency records for every one of
/// them until the table goes away (macOS 27), so updating the tables on each
/// refresh made memory climb by megabytes an hour. The cells read their live
/// values from the monitor instead, and the tables only update when rows appear,
/// disappear or move.
struct StableRow<Sample: Identifiable>: Identifiable, Equatable where Sample.ID == pid_t {
    var sample: Sample
    private var name: String
    var id: pid_t { sample.id }

    init(_ sample: Sample, name: String) {
        self.sample = sample
        self.name = name
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name }
}

/// Keeps a table's order for a few seconds, since every reorder updates the
/// table (see `StableRow`) and the values sorted on change at each refresh.
/// Rows that appear meanwhile go at the end until the next sort.
@MainActor
final class SortThrottle {
    static let interval: TimeInterval = 5
    private var order: [pid_t] = []
    private var key: [AnyHashable] = []
    private var date = Date.distantPast

    func apply<Sample>(_ rows: [StableRow<Sample>], key: [AnyHashable],
                       sort: ([StableRow<Sample>]) -> [StableRow<Sample>]) -> [StableRow<Sample>] {
        let now = Date()
        guard key == self.key, now.timeIntervalSince(date) < Self.interval else {
            let sorted = sort(rows)
            order = sorted.map(\.id)
            self.key = key
            date = now
            return sorted
        }
        var remaining = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = order.compactMap { remaining.removeValue(forKey: $0) }
        if !remaining.isEmpty {
            result += sort(rows.filter { remaining[$0.id] != nil })
            order = result.map(\.id)
        }
        return result
    }
}

/// A cell showing the latest sample of its row's process. The monitor is passed
/// in: SwiftUI also renders table cells outside the page's environment.
private struct LiveCell<Sample: Identifiable, Content: View>: View where Sample.ID == pid_t {
    var monitor: SystemMonitor
    var row: StableRow<Sample>
    var index: KeyPath<SystemMonitor, [pid_t: Sample]>
    @ViewBuilder var content: (Sample) -> Content

    var body: some View { content(monitor[keyPath: index][row.id] ?? row.sample) }
}

// MARK: - Processes

struct ProcessesPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    typealias Row = StableRow<ProcessSample>
    @State private var sortOrder = [KeyPathComparator(\Row.sample.cpu, order: .reverse)]
    @State private var sortThrottle = SortThrottle()
    @State private var selection = Set<pid_t>()
    @State private var search = ""
    @State private var showInspector = false
    @State private var confirmation: PendingSignal?
    @State private var errorMessage: String?
    @AppStorage("processScope") private var scope = ProcessScope.all

    enum ProcessScope: String, CaseIterable {
        case all = "All processes", mine = "My processes"
    }

    struct PendingSignal: Identifiable {
        let id = UUID()
        var signal: ProcessCollector.Signal
        var pids: [pid_t]
    }

    private var rows: [Row] {
        let uid = getuid()
        let rows = monitor.processes
            .filter { scope == .all || $0.uid == uid }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search }
            .map { Row($0, name: $0.name) }
        return sortThrottle.apply(rows, key: [sortOrder, search, scope]) { $0.sorted(using: sortOrder) }
    }

    private func live(_ row: Row, @ViewBuilder _ content: @escaping (ProcessSample) -> some View) -> some View {
        LiveCell(monitor: monitor, row: row, index: \.processesByPID, content: content)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sample.name) { row in
                live(row) { process in
                    HStack(spacing: 8) {
                        ProcessIcon(executablePath: process.executablePath, size: 18)
                        Text(process.name).lineLimit(1)
                        if process.state == .stopped {
                            Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Suspended")
                        }
                    }
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Process ID", value: \.sample.pid) { TrailingText("\($0.id)") }
                .width(min: 50, ideal: 60)
            TableColumn("User", value: \.sample.user) { Text($0.sample.user).lineLimit(1) }
                .width(min: 60, ideal: 90)
            TableColumn("Memory", value: \.sample.memory) { row in
                live(row) { TrailingText($0.isAccessible || $0.memory > 0 ? Format.bytes($0.memory) : "—") }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Processor", value: \.sample.cpu) { row in
                live(row) { process in
                    if process.isAccessible { CPUText(cores: process.cpu, logicalCores: monitor.cpuInfo.logicalCores) } else { TrailingText("—") }
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Threads", value: \.sample.threads) { row in
                live(row) { TrailingText($0.threads > 0 ? "\($0.threads)" : "—") }
            }
            .width(min: 50, ideal: 60)
            TableColumn("Read", value: \.sample.diskReadPerSecond) { row in
                live(row) { TrailingText(Format.rate($0.diskReadPerSecond)) }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Write", value: \.sample.diskWritePerSecond) { row in
                live(row) { TrailingText(Format.rate($0.diskWritePerSecond)) }
            }
            .width(min: 70, ideal: 80)
            TableColumn("GPU", value: \.sample.gpu) { row in
                live(row) { TrailingText(Format.percent($0.gpu, decimals: 1)) }
            }
                .width(min: 50, ideal: 60)
        }
        .contextMenu(forSelectionType: pid_t.self) { pids in
            processMenu(Array(pids))
        } primaryAction: { pids in
            selection = pids
            showInspector = true
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.windowBackground ?? Color(nsColor: .windowBackgroundColor))
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .centeredTitle("Processes", subtitle: "\(rows.count) processes")
        .toolbar {
            ToolbarItem {
                Picker("Scope", selection: $scope) {
                    ForEach(ProcessScope.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.menu)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar {
                Button { showInspector.toggle() } label: { Image(systemName: "info") }
                    .buttonStyle(CircleIconStyle())
                    .help("Show process details")
                    .disabled(selection.isEmpty)
                SplitDestructiveButton(title: "End Process", enabled: !selection.isEmpty) {
                    confirmation = PendingSignal(signal: .terminate, pids: Array(selection))
                } menu: {
                    Button("Kill Process") { confirmation = PendingSignal(signal: .kill, pids: Array(selection)) }
                    Button("Suspend Process") { send(.stop, to: Array(selection)) }
                    Button("Resume Process") { send(.resume, to: Array(selection)) }
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            Group {
                if let pid = selection.first, selection.count == 1, let process = monitor.process(pid) {
                    ProcessDetailView(process: process)
                } else {
                    ContentUnavailableView("No process selected", systemImage: "list.bullet.rectangle")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            presenting: confirmation) { pending in
            Button(pending.signal == .kill ? "Kill" : "End", role: .destructive) { send(pending.signal, to: pending.pids) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.signal == .kill
                 ? "The process will be stopped immediately. Unsaved data will be lost."
                 : "The process will be asked to quit. Unsaved data may be lost.")
        }
        .alert("Could not signal the process", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var confirmationTitle: String {
        guard let pending = confirmation else { return "" }
        let name = pending.pids.count == 1 ? (monitor.process(pending.pids[0])?.name ?? "this process") : "\(pending.pids.count) processes"
        return pending.signal == .kill ? "Kill \(name)?" : "End \(name)?"
    }

    @ViewBuilder
    private func processMenu(_ pids: [pid_t]) -> some View {
        if !pids.isEmpty {
            Button("Show Details") { selection = Set(pids); showInspector = true }
            Divider()
            Button("End") { confirmation = PendingSignal(signal: .terminate, pids: pids) }
            Button("Kill") { confirmation = PendingSignal(signal: .kill, pids: pids) }
            Button("Suspend") { send(.stop, to: pids) }
            Button("Resume") { send(.resume, to: pids) }
            Divider()
            if pids.count == 1, let path = monitor.process(pids[0])?.executablePath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pids.map(String.init).joined(separator: " "), forType: .string)
            }
        }
    }

    private func send(_ signal: ProcessCollector.Signal, to pids: [pid_t]) {
        let errors = pids.compactMap { ProcessCollector.send(signal, to: $0) }
        if let first = errors.first { errorMessage = first }
        monitor.refreshNow()
    }
}

struct ProcessDetailView: View {
    @Environment(SystemMonitor.self) private var monitor
    var process: ProcessSample
    @State private var arguments: [String]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ProcessIcon(executablePath: process.executablePath).scaleEffect(1.6).frame(width: 28)
                    Text(process.name).font(.title2.weight(.semibold)).lineLimit(2)
                }
                BoxedList {
                    ForEach(rows, id: \.0) { PropertyRow($0.0, $0.1) }
                }
                if let path = process.executablePath {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Executable").font(.headline)
                        Text(path).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if let arguments, arguments.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command line").font(.headline)
                        Text(arguments.joined(separator: " ")).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: process.pid) { arguments = ProcessCollector.arguments(of: process.pid) }
    }

    private var rows: [(String, String)] {
        let parent = monitor.process(process.parentPID).map { "\($0.name) (\($0.pid))" } ?? "\(process.parentPID)"
        var rows: [(String, String)] = [
            ("PID", "\(process.pid)"),
            ("Parent", parent),
        ]
        if process.responsiblePID != process.pid, let owner = monitor.process(process.responsiblePID) {
            rows.append(("Responsible", "\(owner.name) (\(owner.pid))"))
        }
        rows += [
            ("User", "\(process.user) (\(process.uid))"),
            ("State", process.state.rawValue),
            ("Started", Format.date(process.startTime)),
            ("CPU", Format.percent(process.cpu / Double(max(monitor.cpuInfo.logicalCores, 1)), decimals: 1)),
            ("CPU time", process.isAccessible ? Format.duration(process.cpuTime) : "—"),
            ("Memory", Format.bytes(process.memory)),
            ("Threads", process.threads > 0 ? "\(process.threads)" : "—"),
            ("Priority", "\(process.priority)"),
            ("GPU", Format.percent(process.gpu, decimals: 1)),
            ("Disk read", "\(Format.rate(process.diskReadPerSecond)) · \(Format.storage(process.totalDiskRead)) total"),
            ("Disk written", "\(Format.rate(process.diskWritePerSecond)) · \(Format.storage(process.totalDiskWritten)) total"),
        ]
        return rows
    }
}

// MARK: - Apps

struct AppsPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    typealias Row = StableRow<AppSample>
    @State private var sortOrder: [KeyPathComparator<Row>]
    @State private var sortThrottle = SortThrottle()
    @State private var selection = Set<pid_t>()
    @State private var search = ""
    @State private var confirmForceQuit: [pid_t]?

    init() {
        // Sorted by name by default; the last column and direction chosen are remembered.
        let defaults = UserDefaults.standard
        let ascending = defaults.object(forKey: "appsSortAscending") as? Bool ?? true
        _sortOrder = State(initialValue: [Self.comparator(defaults.string(forKey: "appsSortColumn") ?? "name",
                                                          order: ascending ? .forward : .reverse)])
    }

    private static let columns: [(String, PartialKeyPath<Row>)] = [
        ("name", \.sample.name), ("memory", \.sample.memory), ("cpu", \.sample.cpu), ("read", \.sample.diskReadPerSecond),
        ("write", \.sample.diskWritePerSecond), ("gpu", \.sample.gpu),
    ]

    private static func comparator(_ column: String, order: SortOrder) -> KeyPathComparator<Row> {
        switch column {
        case "memory": KeyPathComparator(\.sample.memory, order: order)
        case "cpu": KeyPathComparator(\.sample.cpu, order: order)
        case "read": KeyPathComparator(\.sample.diskReadPerSecond, order: order)
        case "write": KeyPathComparator(\.sample.diskWritePerSecond, order: order)
        case "gpu": KeyPathComparator(\.sample.gpu, order: order)
        default: KeyPathComparator(\.sample.name, comparator: .localizedStandard, order: order)
        }
    }

    private var selectedApp: AppSample? {
        guard selection.count == 1, let pid = selection.first else { return nil }
        return monitor.appsByPID[pid]
    }

    private var rows: [Row] {
        let rows = monitor.apps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .map { Row($0, name: $0.name) }
        return sortThrottle.apply(rows, key: [sortOrder, search]) { $0.sorted(using: sortOrder) }
    }

    private func live(_ row: Row, @ViewBuilder _ content: @escaping (AppSample) -> some View) -> some View {
        LiveCell(monitor: monitor, row: row, index: \.appsByPID, content: content)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.sample.name, comparator: .localizedStandard) { row in
                live(row) { app in
                    HStack(spacing: 10) {
                        ProcessIcon(executablePath: nil, bundlePath: app.bundlePath, size: 28)
                        Text(app.name).lineLimit(1)
                        if ProcessCollector.isStopped(app.pid) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(theme.warning)
                                .help("Paused")
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Memory", value: \.sample.memory) { row in live(row) { TrailingText(Format.bytes($0.memory)) } }
                .width(min: 70, ideal: 90)
            TableColumn("Processor", value: \.sample.cpu) { row in live(row) { CPUText(cores: $0.cpu, logicalCores: monitor.cpuInfo.logicalCores) } }
                .width(min: 60, ideal: 70)
            TableColumn("Read", value: \.sample.diskReadPerSecond) { row in live(row) { TrailingText(Format.rate($0.diskReadPerSecond)) } }
                .width(min: 70, ideal: 80)
            TableColumn("Write", value: \.sample.diskWritePerSecond) { row in live(row) { TrailingText(Format.rate($0.diskWritePerSecond)) } }
                .width(min: 70, ideal: 80)
            TableColumn("GPU", value: \.sample.gpu) { row in live(row) { TrailingText(Format.percent($0.gpu, decimals: 1)) } }
                .width(min: 50, ideal: 60)
            TableColumn("Processes") { row in live(row) { TrailingText("\($0.processIDs.count)") } }
                .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: pid_t.self) { pids in
            if !pids.isEmpty {
                Button("Bring to Front") { pids.forEach { NSRunningApplication(processIdentifier: $0)?.activate() } }
                Button("Hide") { pids.forEach { NSRunningApplication(processIdentifier: $0)?.hide() } }
                Divider()
                Button("Quit") { quit(Array(pids)) }
                Button("Force Quit") { confirmForceQuit = Array(pids) }
            }
        } primaryAction: { pids in
            pids.forEach { NSRunningApplication(processIdentifier: $0)?.activate() }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.windowBackground ?? Color(nsColor: .windowBackgroundColor))
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .centeredTitle("Apps", subtitle: "\(rows.count) running apps")
        .onChange(of: monitor.apps.count) {
            // Snapshot mode: preselect an app so the drawer can be checked.
            if selection.isEmpty, let name = ProcessInfo.processInfo.environment["IRESSOURCES_SELECT_APP"],
               let app = monitor.apps.first(where: { $0.name == name }) {
                selection = [app.pid]
            }
        }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first,
                  let column = Self.columns.first(where: { $0.1 == first.keyPath })?.0 else { return }
            UserDefaults.standard.set(column, forKey: "appsSortColumn")
            UserDefaults.standard.set(first.order == .forward, forKey: "appsSortAscending")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let app = selectedApp {
                    AppDetailDrawer(app: app) { selection = [] }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                actionBar
            }
            .animation(motion.animation(.smooth(duration: 0.28)), value: selectedApp?.pid)
        }
        .confirmationDialog("Force quit the selected apps?",
                            isPresented: Binding(get: { confirmForceQuit != nil }, set: { if !$0 { confirmForceQuit = nil } }),
                            presenting: confirmForceQuit) { pids in
            Button("Force Quit", role: .destructive) {
                pids.forEach { NSRunningApplication(processIdentifier: $0)?.forceTerminate() }
                monitor.refreshNow()
            }
        } message: { _ in
            Text("Unsaved changes will be lost.")
        }
    }

    private var selectedApps: [AppSample] {
        monitor.apps.filter { selection.contains($0.pid) }
    }

    private var actionBar: some View {
        let apps = selectedApps
        let paused = !apps.isEmpty && apps.allSatisfy { ProcessCollector.isStopped($0.pid) }
        return ActionBar {
            Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                setPaused(!paused, apps)
            }
            .buttonStyle(PillStyle(tint: paused ? theme.success : theme.warning))
            // Suspending iRessources itself would leave nothing to resume it with.
            .disabled(apps.isEmpty || selection.contains(getpid()))
            .help(paused ? "Resume every process of the app" : "Suspend every process of the app until resumed")

            SplitDestructiveButton(title: "End App", enabled: !selection.isEmpty) {
                quit(Array(selection))
            } menu: {
                Button("Force Quit App") { confirmForceQuit = Array(selection) }
                Divider()
                Button("Bring to Front") { selection.forEach { NSRunningApplication(processIdentifier: $0)?.activate() } }
                Button("Hide App") { selection.forEach { NSRunningApplication(processIdentifier: $0)?.hide() } }
            }
        }
    }

    private func setPaused(_ paused: Bool, _ apps: [AppSample]) {
        for pid in apps.flatMap(\.processIDs) {
            ProcessCollector.send(paused ? .stop : .resume, to: pid)
        }
        monitor.refreshNow()
    }

    private func quit(_ pids: [pid_t]) {
        // A suspended app cannot handle the quit request until it is resumed.
        let apps = monitor.apps.filter { pids.contains($0.pid) && ProcessCollector.isStopped($0.pid) }
        if !apps.isEmpty { setPaused(false, apps) }
        pids.forEach { NSRunningApplication(processIdentifier: $0)?.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { monitor.refreshNow() }
    }
}

// MARK: - Action bar

/// Bottom bar with the primary actions, as in Resources.
private struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// "End App ▾": a destructive pill with a menu of related actions.
private struct SplitDestructiveButton<MenuContent: View>: View {
    var title: String
    var enabled: Bool
    var action: () -> Void
    @ViewBuilder var menu: MenuContent
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Button(title, action: action)
                .buttonStyle(PillStyle(tint: theme.danger))
            Menu {
                menu
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.danger.opacity(enabled ? 1 : 0.45))
                    .frame(width: 26, height: 28)
                    .background(theme.danger.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 2)
        }
        .disabled(!enabled)
    }
}
