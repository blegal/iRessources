// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Panel shown under the Apps list for the selected app: location, live
/// usage and a slider for the scheduling priority of all its processes.
struct AppDetailDrawer: View {
    var app: AppSample
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage(Preferences.normalizeCPU) private var normalizeCPU = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let path = app.bundlePath {
                pathRow(path)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    metric("Memory", Format.bytes(app.memory))
                    metric("Processor", Format.percent(normalizeCPU ? app.cpu / Double(max(monitor.cpuInfo.logicalCores, 1)) : app.cpu, decimals: 1))
                    metric("GPU", Format.percent(app.gpu, decimals: 1))
                }
                GridRow {
                    metric("Disk read · write", "\(Format.rate(app.diskReadPerSecond)) · \(Format.rate(app.diskWritePerSecond))")
                    metric("Threads", app.threads > 0 ? "\(app.threads)" : "—")
                    metric("Launched", app.launchDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                }
            }
            Divider()
            NiceSlider(pids: app.processIDs, mainPID: app.pid)
                .id(app.pid)
            EfficiencyToggle(pids: app.processIDs, mainPID: app.pid)
                .id(app.pid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground ?? Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProcessIcon(executablePath: nil, bundlePath: app.bundlePath, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.headline)
                Text([app.bundleIdentifier, "PID \(app.pid)",
                      "\(app.processIDs.count) process\(app.processIDs.count > 1 ? "es" : "")"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(CircleIconStyle())
                .help("Close")
                .keyboardShortcut(.cancelAction)
        }
    }

    private func pathRow(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Path").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slider from -20 (highest priority) to +20 (lowest). The value is applied
/// when the knob is released, so the administrator prompt appears only once.
private struct NiceSlider: View {
    var pids: [pid_t]
    var mainPID: pid_t

    @Environment(\.theme) private var theme
    @State private var value: Double = 0
    @State private var applied: Int32 = 0
    @State private var isApplying = false
    @State private var error: String?

    private var target: Int32 { Int32(value.rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Priority (nice)").font(.caption).foregroundStyle(.secondary)
                    .help("Applies to every process of the app. On Apple silicon, macOS mostly schedules by "
                          + "quality of service, so the effect of nice is moderate.")
                Spacer()
                if isApplying { ProgressView().controlSize(.small) }
                Text(label(target)).monospacedDigit().fontWeight(.medium)
            }
            Slider(value: $value, in: -20...20, step: 1) {
                Text("Priority")
            } minimumValueLabel: {
                Text("−20").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("+20").font(.caption2).foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                if !editing { apply() }
            }
            .labelsHidden()
            .disabled(isApplying)

            HStack {
                Text("Highest priority").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Lowest priority").font(.caption2).foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(theme.danger)
            } else if target < applied {
                Label("Raising the priority requires an administrator password", systemImage: "lock")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .task {
            let current = ProcessPriority.nice(of: mainPID) ?? 0
            applied = current
            value = Double(current)
        }
    }

    private func label(_ nice: Int32) -> String {
        let sign = nice > 0 ? "+" : ""
        let meaning = nice < 0 ? "Higher" : nice > 0 ? "Lower" : "Normal"
        return "\(sign)\(nice) · \(meaning)"
    }

    private func apply() {
        let requested = target
        guard requested != applied else { return }
        error = nil
        isApplying = true
        Task {
            let failure = await ProcessPriority.setNice(requested, for: pids)
            isApplying = false
            // Read back what the kernel actually holds rather than trusting the request.
            let actual = ProcessPriority.nice(of: mainPID) ?? applied
            applied = actual
            value = Double(actual)
            if let failure, failure != "Cancelled" { error = failure }
        }
    }
}

/// Confines the app to the most power-efficient cores using the Darwin
/// background policy (efficiency cores on most Macs, the lowest
/// performance level on chips without them).
private struct EfficiencyToggle: View {
    var pids: [pid_t]
    var mainPID: pid_t

    @Environment(\.theme) private var theme
    @Environment(SystemMonitor.self) private var monitor
    @State private var isOn = false
    @State private var isApplying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Background mode")
                    Text("\(coreDescription), and slows down disk and network access. Useful for long jobs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isApplying { ProgressView().controlSize(.small) }
                Toggle("Background mode", isOn: Binding(get: { isOn }, set: apply))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(isApplying)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(theme.danger)
            }
        }
        .task { isOn = ProcessPriority.isBackground(mainPID) }
    }

    /// "Keeps it on the efficiency cores instead of the performance cores" — or, on
    /// chips such as the M5 Max, the performance cores instead of the super cores.
    private var coreDescription: String {
        let levels = monitor.cpuInfo.performanceLevels
        guard levels.count > 1, let fast = levels.first?.name, let slow = levels.last?.name else {
            return "Lowers its CPU priority"
        }
        return "Keeps it on the \(slow.lowercased()) cores instead of the \(fast.lowercased()) cores"
    }

    private func apply(_ enabled: Bool) {
        error = nil
        isOn = enabled
        isApplying = true
        Task {
            let failure = await ProcessPriority.setBackground(enabled, for: pids)
            isApplying = false
            isOn = ProcessPriority.isBackground(mainPID)
            if let failure, failure != "Cancelled" { error = failure }
        }
    }
}
