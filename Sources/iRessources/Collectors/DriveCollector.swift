// iRessources — SPDX-License-Identifier: GPL-3.0-or-later
//
// Drives are the IOBlockStorageDriver instances (one per physical or virtual
// disk). Their "Statistics" dictionary carries cumulative I/O counters.
// Mounted volumes are attached to the drive that backs them by walking up the
// IOKit service plane from the volume's IOMedia.

import Foundation
import IOKit

struct VolumeInfo: Hashable, Identifiable {
    var id: String { mountPoint }
    var name: String
    var mountPoint: String
    var fileSystem: String
    var total: UInt64
    var available: UInt64
    var used: UInt64 { total > available ? total - available : 0 }
}

struct DriveSample: Identifiable {
    var id: UInt64
    var bsdName: String
    var model: String
    var kind: String            // "SSD", "HDD", "Disk image"…
    var interconnect: String?
    var isInternal: Bool
    var isRemovable: Bool
    var capacity: UInt64
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var totalRead: UInt64
    var totalWritten: UInt64
    var activeRatio: Double = 0 // fraction of the interval spent doing I/O
    var volumes: [VolumeInfo] = []
}

final class DriveCollector {
    private struct Counters { var read: UInt64; var written: UInt64; var busyNanoseconds: UInt64 }
    private var previous: [UInt64: Counters] = [:]
    private var previousTime = Date()
    private var volumeCache: (date: Date, map: [UInt64: [VolumeInfo]])?

    func sample() -> [DriveSample] {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(previousTime), 0.001)
        let volumes = volumesByDrive(now: now)
        var drives: [DriveSample] = []
        var counters: [UInt64: Counters] = [:]

        IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            let id = IORegistry.entryID(driver)
            let stats = IORegistry.property("Statistics", of: driver) as? [String: Any] ?? [:]
            func stat(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }

            var media: (bsd: String, size: UInt64, removable: Bool)?
            IORegistry.children(of: driver) { child in
                guard media == nil, IOObjectConformsTo(child, "IOMedia") != 0 else { return }
                let props = IORegistry.properties(of: child)
                media = (props["BSD Name"] as? String ?? "?",
                         (props["Size"] as? NSNumber)?.uint64Value ?? 0,
                         (props["Removable"] as? Bool) ?? false)
            }
            guard let media, media.size > 0 else { return }
            let driveVolumes = volumes[id] ?? []

            let device = IORegistry.searchProperty("Device Characteristics", of: driver) as? [String: Any] ?? [:]
            let proto = IORegistry.searchProperty("Protocol Characteristics", of: driver) as? [String: Any] ?? [:]
            let interconnect = proto["Physical Interconnect"] as? String
            let location = proto["Physical Interconnect Location"] as? String
            let isImage = interconnect == "Virtual Interface" || location == "File"
            // A disk image is only worth showing while one of its volumes is visible in Finder.
            if isImage && driveVolumes.isEmpty { return }

            let current = Counters(
                read: stat("Bytes (Read)"),
                written: stat("Bytes (Write)"),
                busyNanoseconds: stat("Total Time (Read)") + stat("Total Time (Write)")
            )
            counters[id] = current

            var drive = DriveSample(
                id: id,
                bsdName: media.bsd,
                model: (device["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Drive",
                kind: isImage ? "Disk image" : Self.kind(from: device["Medium Type"] as? String),
                interconnect: interconnect,
                isInternal: location == "Internal",
                isRemovable: media.removable,
                capacity: media.size,
                totalRead: current.read,
                totalWritten: current.written,
                volumes: driveVolumes
            )
            if let before = previous[id] {
                drive.readBytesPerSecond = Double(current.read &- before.read) / elapsed
                drive.writeBytesPerSecond = Double(current.written &- before.written) / elapsed
                drive.activeRatio = min(Double(current.busyNanoseconds &- before.busyNanoseconds) / (elapsed * 1e9), 1)
            }
            drives.append(drive)
        }

        previous = counters
        previousTime = now
        return drives.sorted { ($0.isInternal ? 0 : 1, $0.bsdName) < ($1.isInternal ? 0 : 1, $1.bsdName) }
    }

    private static func kind(from medium: String?) -> String {
        switch medium {
        case "Solid State": return "SSD"
        case "Rotational": return "HDD"
        default: return "Drive"
        }
    }

    // MARK: - Volumes

    /// Volume lists change rarely; refresh them every 15 seconds only.
    private func volumesByDrive(now: Date) -> [UInt64: [VolumeInfo]] {
        if let cache = volumeCache, now.timeIntervalSince(cache.date) < 15 { return cache.map }

        var map: [UInt64: [VolumeInfo]] = [:]
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [:] }

        for i in 0..<Int(count) {
            var fs = mounts[i]
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard from.hasPrefix("/dev/disk") else { continue }
            // Skip the read-only system internals that only add noise.
            if on.hasPrefix("/System/Volumes/") && on != "/System/Volumes/Data" { continue }
            // Volumes hidden from Finder (Recovery, images an updater mounted in a temporary folder…).
            if fs.f_flags & UInt32(MNT_DONTBROWSE) != 0 && on != "/System/Volumes/Data" { continue }

            let bsd = String(from.dropFirst("/dev/".count))
            guard let driveID = backingDriverID(forBSDName: bsd) else { continue }

            let url = URL(fileURLWithPath: on)
            let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = UInt64(fs.f_blocks) * UInt64(fs.f_bsize)
            var available = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
                available = UInt64(important)
            }
            let name = on == "/" ? "Macintosh HD" : (values?.volumeLocalizedName ?? url.lastPathComponent)
            // "/" and "/System/Volumes/Data" share an APFS container; keep a single entry.
            if on == "/System/Volumes/Data", map[driveID]?.contains(where: { $0.mountPoint == "/" }) == true { continue }
            map[driveID, default: []].append(VolumeInfo(name: name, mountPoint: on, fileSystem: type,
                                                        total: total, available: min(available, total)))
        }
        volumeCache = (now, map)
        return map
    }

    private func backingDriverID(forBSDName bsd: String) -> UInt64? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        // Walk up until the nearest block storage driver; for APFS this crosses
        // the container and lands on the physical disk's driver.
        var found: UInt64?
        var lastDriver: UInt64?
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                lastDriver = IORegistry.entryID(entry)
                // A synthesized APFS container disk also has a driver; prefer the physical one above it.
                let isSynthesized = IORegistry.searchProperty("Protocol Characteristics", of: entry)
                    .flatMap { ($0 as? [String: Any])?["Physical Interconnect"] as? String } == nil
                if !isSynthesized { found = lastDriver; IOObjectRelease(entry); break }
            }
            let parent = IORegistry.parent(of: entry)
            IOObjectRelease(entry)
            entry = parent ?? 0
        }
        return found ?? lastDriver
    }
}
