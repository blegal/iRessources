// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Shared CPU formatting: either a share of the whole machine or of one core.
private struct CPUText: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage("normalizeCPU") private var normalize = true
    var cores: Double

    var body: some View {
        let value = normalize ? cores / Double(max(monitor.cpuInfo.logicalCores, 1)) : cores
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

// MARK: - Processes

struct ProcessesPage: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(\.theme) private var theme
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpu, order: .reverse)]
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

    private var rows: [ProcessSample] {
        let uid = getuid()
        return monitor.processes
            .filter { scope == .all || $0.uid == uid }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { process in
                HStack(spacing: 8) {
                    ProcessIcon(executablePath: process.executablePath, size: 18)
                    Text(process.name).lineLimit(1)
                    if process.state == .stopped {
                        Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Suspended")
                    }
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Process ID", value: \.pid) { TrailingText("\($0.pid)") }
                .width(min: 50, ideal: 60)
            TableColumn("User", value: \.user) { Text($0.user).lineLimit(1) }
                .width(min: 60, ideal: 90)
            TableColumn("Memory", value: \.memory) { process in
                TrailingText(process.isAccessible || process.memory > 0 ? Format.bytes(process.memory) : "—")
            }
            .width(min: 70, ideal: 90)
            TableColumn("Processor", value: \.cpu) { process in
                if process.isAccessible { CPUText(cores: process.cpu) } else { TrailingText("—") }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Threads", value: \.threads) { process in
                TrailingText(process.threads > 0 ? "\(process.threads)" : "—")
            }
            .width(min: 50, ideal: 60)
            TableColumn("Read", value: \.diskReadPerSecond) { TrailingText(Format.rate($0.diskReadPerSecond)) }
                .width(min: 70, ideal: 80)
            TableColumn("Write", value: \.diskWritePerSecond) { TrailingText(Format.rate($0.diskWritePerSecond)) }
                .width(min: 70, ideal: 80)
            TableColumn("GPU", value: \.gpu) { TrailingText(Format.percent($0.gpu, decimals: 1)) }
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
    @State private var sortOrder = [KeyPathComparator(\AppSample.memory, order: .reverse)]
    @State private var selection = Set<pid_t>()
    @State private var search = ""
    @State private var confirmForceQuit: [pid_t]?

    private var rows: [AppSample] {
        monitor.apps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { app in
                HStack(spacing: 10) {
                    ProcessIcon(executablePath: nil, bundlePath: app.bundlePath, size: 28)
                    Text(app.name).lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .width(min: 160, ideal: 220)
            TableColumn("Memory", value: \.memory) { TrailingText(Format.bytes($0.memory)) }
                .width(min: 70, ideal: 90)
            TableColumn("Processor", value: \.cpu) { CPUText(cores: $0.cpu) }
                .width(min: 60, ideal: 70)
            TableColumn("Read", value: \.diskReadPerSecond) { TrailingText(Format.rate($0.diskReadPerSecond)) }
                .width(min: 70, ideal: 80)
            TableColumn("Write", value: \.diskWritePerSecond) { TrailingText(Format.rate($0.diskWritePerSecond)) }
                .width(min: 70, ideal: 80)
            TableColumn("GPU", value: \.gpu) { TrailingText(Format.percent($0.gpu, decimals: 1)) }
                .width(min: 50, ideal: 60)
            TableColumn("Processes") { TrailingText("\($0.processIDs.count)") }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar {
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

    private func quit(_ pids: [pid_t]) {
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
                .buttonStyle(DestructivePillStyle())
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
