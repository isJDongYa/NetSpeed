import Foundation
import SystemConfiguration
import Darwin

struct InterfaceCounter: Equatable {
    let name: String
    let index: UInt32
    let received: UInt64
    let sent: UInt64
    let flags: Int32

    var isActive: Bool {
        flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 && flags & IFF_LOOPBACK == 0
    }
}

enum NetworkReadError: LocalizedError {
    case system(Int32)
    case malformedSnapshot

    var errorDescription: String? {
        switch self {
        case .system(let code): return "暂时无法读取网速（\(String(cString: strerror(code)))）"
        case .malformedSnapshot: return "暂时无法读取网速（系统数据不完整）"
        }
    }
}

/// Reads 64-bit kernel counters. Reading both a physical interface and its VPN
/// tunnel would count the same transfer twice, so the UI selects one interface.
struct NetworkReader {
    static func snapshot() throws -> [String: InterfaceCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
                throw NetworkReadError.system(errno)
            }
            var bytes = [UInt8](repeating: 0, count: length)
            let result = bytes.withUnsafeMutableBytes { raw in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &length, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                throw NetworkReadError.system(errno)
            }
            return try bytes.withUnsafeBytes { raw in
                try parse(raw, length: length)
            }
        }
        throw NetworkReadError.system(ENOMEM)
    }

    static func parse(_ bytes: UnsafeRawBufferPointer, length: Int) throws -> [String: InterfaceCounter] {
        guard length <= bytes.count else { throw NetworkReadError.malformedSnapshot }
        var offset = 0
        var interfaces: [String: InterfaceCounter] = [:]
        while offset < length {
            guard offset + 4 <= length else { throw NetworkReadError.malformedSnapshot }
            let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard messageLength >= 4, offset + messageLength <= length else {
                throw NetworkReadError.malformedSnapshot
            }
            let messageType = bytes[offset + 3]
            if messageType == UInt8(RTM_IFINFO2) {
                guard messageLength >= MemoryLayout<if_msghdr2>.size else {
                    throw NetworkReadError.malformedSnapshot
                }
                let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBytes = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(message.ifm_index), &nameBytes) != nil {
                    let name = String(cString: nameBytes)
                    interfaces[name] = InterfaceCounter(
                        name: name, index: UInt32(message.ifm_index),
                        received: message.ifm_data.ifi_ibytes,
                        sent: message.ifm_data.ifi_obytes, flags: message.ifm_flags
                    )
                }
            }
            offset += messageLength
        }
        return interfaces
    }

    static func primaryInterface(in counters: [String: InterfaceCounter]) -> String? {
        for family in ["IPv4", "IPv6"] {
            let key = "State:/Network/Global/\(family)" as CFString
            if let state = SCDynamicStoreCopyValue(nil, key) as? [String: Any],
               let name = state["PrimaryInterface"] as? String,
               counters[name]?.isActive == true {
                return name
            }
        }
        return nil
    }

    static func interfaceNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            names[name] = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return names
    }
}

struct TransferRate: Equatable {
    let download: Double
    let upload: Double
}

struct RateCalculator {
    private var previous: (counter: InterfaceCounter, time: TimeInterval)?

    mutating func reset() { previous = nil }

    mutating func update(_ counter: InterfaceCounter?, at time: TimeInterval) -> TransferRate? {
        guard let counter, counter.isActive else {
            reset()
            return nil
        }
        defer { previous = (counter, time) }
        guard let old = previous,
              old.counter.name == counter.name,
              old.counter.index == counter.index else { return nil }
        let elapsed = time - old.time
        // A wake, clock discontinuity or delayed timer starts a fresh sample.
        guard elapsed > 0, elapsed <= 5 else { return nil }
        guard counter.received >= old.counter.received, counter.sent >= old.counter.sent else {
            return nil
        }
        return TransferRate(
            download: Double(counter.received - old.counter.received) / elapsed,
            upload: Double(counter.sent - old.counter.sent) / elapsed
        )
    }
}

enum SpeedUnit: String, CaseIterable {
    case bytes, bits

    var menuTitle: String {
        self == .bytes ? "字节 / 秒（KB/s、MB/s）" : "比特 / 秒（Mbps）"
    }

    func format(_ bytesPerSecond: Double) -> String {
        let units = self == .bytes ? ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"] : ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) * (self == .bits ? 8 : 1) : 0
        var unitIndex = 0
        while value >= 999.5, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        let pattern = value == 0 || value >= 100 || unitIndex == 0 ? "%.0f" : value >= 10 ? "%.1f" : "%.2f"
        return String(format: pattern, locale: Locale(identifier: "en_US_POSIX"), value) + " " + units[unitIndex]
    }
}

func runSelfTests() throws {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        checks += 1
    }
    func counter(_ received: UInt64, _ sent: UInt64, name: String = "en0", index: UInt32 = 1, active: Bool = true) -> InterfaceCounter {
        InterfaceCounter(name: name, index: index, received: received, sent: sent,
                         flags: active ? IFF_UP | IFF_RUNNING : 0)
    }
    var rates = RateCalculator()
    expect(rates.update(counter(5_000_000_000, 8_000_000_000), at: 1) == nil, "first sample is a baseline")
    expect(rates.update(counter(5_000_002_000, 8_000_001_000), at: 3) == TransferRate(download: 1_000, upload: 500), "64-bit counters and real elapsed time")
    expect(rates.update(counter(10, 20), at: 4) == nil, "counter reset cannot create a spike")
    expect(rates.update(counter(1_010, 1_020), at: 5) == TransferRate(download: 1_000, upload: 1_000), "resume after counter reset")
    expect(rates.update(counter(5_000, 5_000, name: "utun4", index: 9), at: 6) == nil, "interface switch starts fresh")
    expect(rates.update(counter(6_000, 6_000, name: "utun4", index: 10), at: 7) == nil, "recreated interface starts fresh")
    expect(rates.update(counter(1_000_000, 1_000_000, name: "utun4", index: 10), at: 100) == nil, "wake or delayed timer cannot create a spike")
    expect(rates.update(nil, at: 101) == nil, "disconnect clears baseline")
    expect(rates.update(counter(100, 100), at: 102) == nil, "reconnect starts fresh")
    expect(rates.update(counter(100, 100), at: 102) == nil, "zero elapsed time is rejected")
    expect(rates.update(counter(100, 100, active: false), at: 103) == nil, "inactive interface is rejected")
    expect(SpeedUnit.bytes.format(1_000_000) == "1.00 MB/s", "decimal byte units")
    expect(SpeedUnit.bits.format(1_000_000) == "8.00 Mbps", "bits convert by eight")
    expect(SpeedUnit.bytes.format(.nan) == "0 B/s", "invalid rates are safe")
    expect(SpeedUnit.bytes.format(-100) == "0 B/s", "negative rates are safe")
    expect(SpeedUnit.bytes.format(999_600) == "1.00 MB/s", "rounded unit boundary stays compact")
    let malformed: [UInt8] = [0, 0, 0, UInt8(RTM_IFINFO2)]
    do {
        _ = try malformed.withUnsafeBytes { try NetworkReader.parse($0, length: malformed.count) }
        expect(false, "malformed kernel message is rejected")
    } catch { checks += 1 }
    let snapshot = try NetworkReader.snapshot()
    expect(!snapshot.isEmpty, "real kernel snapshot is readable")
    expect(snapshot.values.contains { $0.name == "lo0" }, "kernel snapshot includes a known interface")
    expect(snapshot["lo0"]?.isActive == false, "loopback is excluded from measurement")
    print("PASS: \(checks) checks")
}
