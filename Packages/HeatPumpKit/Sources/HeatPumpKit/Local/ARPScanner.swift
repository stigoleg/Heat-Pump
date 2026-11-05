import Darwin
import Foundation

/// Finds a device on the Mac's own /24 by hardware address, entirely in-process:
/// reads the ARP table with `sysctl`, and if the address is not there, sends one empty UDP
/// datagram (discard port 9) to each address of the subnet so the kernel resolves them, then
/// reads the table again. No TCP connections, no shell tools, nothing leaves the subnet.
public struct ARPScanner: LocalNetworkScanning {
    /// Time given to ARP replies after the sweep.
    var settle: Duration = .seconds(2)

    public init() {}

    public func hosts(matchingMAC mac: String) async throws -> [String] {
        guard let wanted = normalizedMAC(mac) else { return [] }
        if let found = Self.lookup(wanted) { return found }
        guard let (own, base) = Self.localSubnets().first else { return [] }
        Self.sweep(base: base, skip: own)
        try await Task.sleep(for: settle)
        if let found = Self.lookup(wanted) { return found }
        // Slow devices answer late; one more look before giving up.
        try await Task.sleep(for: .milliseconds(1500))
        return Self.lookup(wanted) ?? []
    }

    private static func lookup(_ mac: String) -> [String]? {
        let found = arpTable().filter { $0.mac == mac }.map(\.ip)
        return found.isEmpty ? nil : found
    }

    // MARK: Interface

    /// Active, non-loopback Ethernet/Wi-Fi interfaces with a private IPv4 address:
    /// (own address, network base of its /24), host byte order.
    static func localSubnets() -> [(own: UInt32, base: UInt32)] {
        var result: [(own: UInt32, base: UInt32)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                String(cString: entry.pointee.ifa_name).hasPrefix("en")
            else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard LocalSmartClient.validatedHost(dotted(ip)) != nil else { continue }
            result.append((ip, ip & 0xFFFF_FF00))
        }
        return result
    }

    static func dotted(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }

    // MARK: Sweep

    /// One empty UDP datagram to port 9 (discard) on .1–.254, paced so the network is not flooded.
    static func sweep(base: UInt32, skip: UInt32) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        for host in UInt32(1)...254 {
            let ip = base | host
            guard ip != skip else { continue }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            address.sin_addr = in_addr(s_addr: ip.bigEndian)
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, &byte, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if host.isMultiple(of: 32) { usleep(20_000) }
        }
    }

    // MARK: ARP table

    struct Entry: Equatable {
        var ip: String
        /// 12 lowercase hex digits.
        var mac: String
    }

    /// The kernel's ARP table (`sysctl` NET_RT_FLAGS / RTF_LLINFO), complete entries only.
    static func arpTable() -> [Entry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }
        return parseRouteMessages(Array(buffer.prefix(length)))
    }

    /// Parses `rt_msghdr` + `sockaddr_in` + `sockaddr_dl` records.
    static func parseRouteMessages(_ buffer: [UInt8]) -> [Entry] {
        var entries: [Entry] = []
        let headerSize = MemoryLayout<rt_msghdr>.size
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= raw.count {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength > 0, offset + messageLength <= raw.count else { break }
                defer { offset += messageLength }
                let inetOffset = offset + headerSize
                guard inetOffset + 8 <= offset + messageLength else { continue }
                let inetLength = Int(raw[inetOffset])
                guard raw[inetOffset + 1] == UInt8(AF_INET) else { continue }
                let ip = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: inetOffset + 4, as: UInt32.self))
                // Socket addresses are padded to 4-byte multiples.
                let rounded = inetLength > 0 ? 1 + ((inetLength - 1) | 3) : 4
                let dl = inetOffset + rounded
                guard dl + 8 <= offset + messageLength, raw[dl + 1] == UInt8(AF_LINK) else { continue }
                let nameLength = Int(raw[dl + 5])
                let addressLength = Int(raw[dl + 6])
                let start = dl + 8 + nameLength
                guard addressLength == 6, start + 6 <= offset + messageLength else { continue }
                let mac = (0..<6).map { String(format: "%02x", raw[start + $0]) }.joined()
                guard mac != "000000000000", mac != "ffffffffffff" else { continue }
                entries.append(Entry(ip: dotted(ip), mac: mac))
            }
        }
        return entries
    }
}
