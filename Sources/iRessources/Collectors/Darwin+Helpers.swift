// iRessources — SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import IOKit

// MARK: - sysctl

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        case 8:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    static func value<T>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

// MARK: - Mach time

enum MachTime {
    /// Multiplier converting mach absolute time units into nanoseconds.
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
}

// MARK: - IOKit

enum IORegistry {
    /// Iterates over every service matching `className`, releasing each one afterwards.
    static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dict
    }

    static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Looks for `key` on the entry and, if missing, on its ancestors.
    static func searchProperty(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    static func entryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &buffer)
        return String(cString: buffer)
    }

    /// Returns the retained parent entry in the service plane, or nil.
    static func parent(of entry: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        return parent
    }

    static func children(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
    }
}

/// Decodes the string-or-data values that IOKit uses for names and models.
func ioString(_ value: Any?) -> String? {
    switch value {
    case let string as String:
        return string
    case let data as Data:
        let trimmed = data.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8)
    default:
        return nil
    }
}

func ioInt(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber: return number.intValue
    case let data as Data where data.count >= 4:
        return data.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
    default: return nil
    }
}
