// iRessources — SPDX-License-Identifier: GPL-3.0-or-later
//
// Interface counters come from the routing socket sysctl (NET_RT_IFLIST2),
// which exposes 64-bit byte counters. Display names come from
// SystemConfiguration, Wi-Fi details from CoreWLAN.

import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

struct WiFiDetails: Hashable {
    var ssid: String?
    var rssi: Int
    var noise: Int
    var transmitRateMbps: Double
    var channel: String?
    var phyMode: String?
}

struct NetworkSample: Identifiable {
    var id: String { bsdName }
    var bsdName: String
    var displayName: String
    var kind: Kind
    var isUp: Bool
    var macAddress: String?
    var ipv4: [String]
    var ipv6: [String]
    var mtu: Int
    var linkSpeedBitsPerSecond: UInt64
    var receivedBytesPerSecond: Double = 0
    var sentBytesPerSecond: Double = 0
    var totalReceived: UInt64
    var totalSent: UInt64
    var wifi: WiFiDetails?

    enum Kind: String {
        case ethernet = "Ethernet", wifi = "Wi-Fi", bridge = "Bridge", vpn = "VPN", cellular = "Cellular"
        case thunderbolt = "Thunderbolt", other = "Network"

        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .ethernet, .thunderbolt: "cable.connector.horizontal"
            case .vpn: "lock.shield"
            case .bridge: "point.3.connected.trianglepath.dotted"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .other: "network"
            }
        }
    }
}

final class NetworkCollector {
    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousTime = Date()
    private var scNames: [String: (name: String, type: String)] = [:]
    private var scNamesDate = Date.distantPast
    // CoreWLAN queries are XPC calls to the Wi-Fi daemon; refresh them sparingly.
    private lazy var wifiInterface = CWWiFiClient.shared().interface()
    private var wifiCache: (date: Date, details: WiFiDetails)?

    func sample() -> [NetworkSample] {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(previousTime), 0.001)
        refreshSystemConfigurationNames(now: now)
        let addresses = Self.addresses()

        var result: [NetworkSample] = []
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]

        for raw in Self.interfaceCounters() {
            let name = raw.name
            guard name != "lo0" else { continue }
            let address = addresses[name]
            let sc = scNames[name]
            let hasRoutableAddress = !(address?.ipv4.isEmpty ?? true) || !(address?.ipv6.filter { !$0.hasPrefix("fe80") }.isEmpty ?? true)
            // Show connected interfaces, Wi-Fi, and anything that carried traffic; idle
            // Thunderbolt ports and bridges would only clutter the sidebar.
            let isWiFi = sc?.type == "IEEE80211"
            guard hasRoutableAddress && raw.isUp || isWiFi || (sc != nil && raw.rx + raw.tx > 0) else { continue }

            counters[name] = (raw.rx, raw.tx)
            var kind = Self.kind(scType: sc?.type, name: name)
            var wifi: WiFiDetails?
            if sc?.type == "IEEE80211" {
                kind = .wifi
                wifi = wifiDetails(now: now)
            }

            var sample = NetworkSample(
                bsdName: name,
                displayName: sc?.name ?? (kind == .vpn ? "VPN (\(name))" : name),
                kind: kind,
                isUp: raw.isUp,
                macAddress: address?.mac,
                ipv4: address?.ipv4 ?? [],
                ipv6: address?.ipv6 ?? [],
                mtu: raw.mtu,
                linkSpeedBitsPerSecond: raw.baudrate,
                totalReceived: raw.rx,
                totalSent: raw.tx,
                wifi: wifi
            )
            if let before = previous[name] {
                sample.receivedBytesPerSecond = Double(raw.rx &- before.rx) / elapsed
                sample.sentBytesPerSecond = Double(raw.tx &- before.tx) / elapsed
            }
            result.append(sample)
        }

        previous = counters
        previousTime = now
        // Active interfaces first, then by name.
        return result.sorted {
            ($0.isUp && !$0.ipv4.isEmpty ? 0 : 1, $0.bsdName) < ($1.isUp && !$1.ipv4.isEmpty ? 0 : 1, $1.bsdName)
        }
    }

    private func wifiDetails(now: Date) -> WiFiDetails? {
        if let cache = wifiCache, now.timeIntervalSince(cache.date) < 10 { return cache.details }
        guard let wifiInterface else { return nil }
        let details = WiFiDetails(
            ssid: wifiInterface.ssid(),
            rssi: wifiInterface.rssiValue(),
            noise: wifiInterface.noiseMeasurement(),
            transmitRateMbps: wifiInterface.transmitRate(),
            channel: wifiInterface.wlanChannel().map(Self.describe),
            phyMode: Self.describe(wifiInterface.activePHYMode())
        )
        wifiCache = (now, details)
        return details
    }

    // MARK: - Counters

    private struct RawInterface { var name: String; var isUp: Bool; var rx: UInt64; var tx: UInt64; var mtu: Int; var baudrate: UInt64 }

    private static func interfaceCounters() -> [RawInterface] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [] }

        var result: [RawInterface] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil {
                        result.append(RawInterface(
                            name: String(cString: nameBuffer),
                            isUp: msg.ifm_flags & IFF_UP != 0 && msg.ifm_flags & IFF_RUNNING != 0,
                            rx: msg.ifm_data.ifi_ibytes,
                            tx: msg.ifm_data.ifi_obytes,
                            mtu: Int(msg.ifm_data.ifi_mtu),
                            baudrate: msg.ifm_data.ifi_baudrate
                        ))
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    // MARK: - Addresses

    private struct Addresses { var ipv4: [String] = []; var ipv6: [String] = []; var mac: String? }

    private static func addresses() -> [String: Addresses] {
        var result: [String: Addresses] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sa = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            switch Int32(sa.pointee.sa_family) {
            case AF_INET, AF_INET6:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: host).components(separatedBy: "%").first ?? ""
                    if sa.pointee.sa_family == UInt8(AF_INET) { result[name, default: .init()].ipv4.append(address) }
                    else { result[name, default: .init()].ipv6.append(address) }
                }
            case AF_LINK:
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let length = Int(dl.pointee.sdl_alen)
                    guard length == 6 else { return }
                    let nameLength = Int(dl.pointee.sdl_nlen)
                    // sdl_data is declared as 12 bytes but the address may extend past it.
                    let base = UnsafeRawPointer(dl) + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
                    let bytes = (0..<length).map { base.load(fromByteOffset: nameLength + $0, as: UInt8.self) }
                    guard bytes.contains(where: { $0 != 0 }) else { return }
                    result[name, default: .init()].mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Naming

    private func refreshSystemConfigurationNames(now: Date) {
        guard now.timeIntervalSince(scNamesDate) > 10 else { return }
        scNamesDate = now
        var names: [String: (String, String)] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String? ?? ""
            names[bsd] = (display, type)
        }
        scNames = names
    }

    private static func kind(scType: String?, name: String) -> NetworkSample.Kind {
        switch scType {
        case "IEEE80211"?: return .wifi
        case "Ethernet"?: return name.hasPrefix("en") ? .ethernet : .other
        case "Bridge"?: return .bridge
        case "WWAN"?: return .cellular
        case "Thunderbolt"?: return .thunderbolt
        case nil where name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp"): return .vpn
        default: return name.hasPrefix("bridge") ? .bridge : .other
        }
    }

    private static func describe(_ channel: CWChannel) -> String {
        let band: String
        switch channel.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = ""
        }
        let width: String
        switch channel.channelWidth {
        case .width20MHz: width = "20 MHz"
        case .width40MHz: width = "40 MHz"
        case .width80MHz: width = "80 MHz"
        case .width160MHz: width = "160 MHz"
        default: width = ""
        }
        return ["\(channel.channelNumber)", band, width].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func describe(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "Wi-Fi 4 (802.11n)"
        case .mode11ac: "Wi-Fi 5 (802.11ac)"
        case .mode11ax: "Wi-Fi 6 (802.11ax)"
        default: nil
        }
    }
}
