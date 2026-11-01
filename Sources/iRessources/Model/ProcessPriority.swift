// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Reads and changes the scheduling priority ("nice" value) and the Darwin
/// background policy of processes.
///
/// Unprivileged users may only make their own processes nicer (raise the
/// value). Anything else — lowering the value or touching another user's
/// process — goes through `renice` run with administrator privileges, which
/// shows the standard macOS authentication dialog.
enum ProcessPriority {
    static let range: ClosedRange<Int32> = -20...20

    static func nice(of pid: pid_t) -> Int32? {
        errno = 0
        let value = getpriority(PRIO_PROCESS, id_t(pid))
        return errno == 0 ? value : nil
    }

    /// Applies `value` to every pid. Returns nil on success, an error message otherwise.
    static func setNice(_ value: Int32, for pids: [pid_t]) async -> String? {
        var denied: [pid_t] = []
        for pid in pids where setpriority(PRIO_PROCESS, id_t(pid), value) != 0 {
            // Processes that exited meanwhile are not an error.
            if errno == EPERM || errno == EACCES { denied.append(pid) }
        }
        guard !denied.isEmpty else { return nil }
        return await reniceAsAdministrator(value, pids: denied)
    }

    // MARK: - Efficiency cores

    // From xnu's proc_info.h; not exported by the macOS SDK.
    private static let darwinBackgroundFlags: UInt32 = 0x8000 | 0x10000 // PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG

    /// True when the process runs under the Darwin background policy: confined to
    /// the efficiency cores on Apple silicon, with throttled disk and network I/O.
    static func isBackground(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_flags & darwinBackgroundFlags != 0
    }

    /// Moves every pid in or out of the background policy (what `taskpolicy -b`/`-B` does).
    static func setBackground(_ enabled: Bool, for pids: [pid_t]) async -> String? {
        var denied: [pid_t] = []
        for pid in pids where setpriority(PRIO_DARWIN_PROCESS, id_t(pid), enabled ? PRIO_DARWIN_BG : 0) != 0 {
            if errno == EPERM || errno == EACCES { denied.append(pid) }
        }
        guard !denied.isEmpty else { return nil }
        let flag = enabled ? "-b" : "-B"
        let command = denied.map { "/usr/sbin/taskpolicy \(flag) -p \($0)" }.joined(separator: "; ")
        return await runAsAdministrator(command)
    }

    private static func reniceAsAdministrator(_ value: Int32, pids: [pid_t]) async -> String? {
        // `renice -n` is an increment on macOS; the bare form sets the absolute value.
        await runAsAdministrator("/usr/bin/renice \(value) -p \(pids.map(String.init).joined(separator: " "))")
    }

    /// Runs a shell command through the standard macOS authentication dialog.
    private static func runAsAdministrator(_ command: String) async -> String? {
        let script = "do shell script \"\(command)\" with administrator privileges"

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { process in
                guard process.terminationStatus != 0 else { return continuation.resume(returning: nil) }
                let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // -128 is "User canceled" in the authentication dialog.
                continuation.resume(returning: message.contains("-128") ? "Cancelled" : message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }
}
