import Foundation
import HeatPumpKit

/// Pure decoding of CN105 status frames as returned in the adapter's `<CODE><VALUE>` list.
/// Offsets are full-frame indices (frame[0] = 0xFC).
public enum CN105Parser {
    public static let noError = LocalSample.noErrorCode
    /// The 16-bit energy counter in 0.1 kWh wraps after this many kWh.
    public static let counterWrapKWh = LocalSample.counterWrapKWh

    public enum FrameError: Error, Equatable {
        case notHex
        case tooShort
        case badHeader
        case badChecksum
    }

    public static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return out
    }

    /// FCC: 0x100 minus the sum of the first 20 bytes after 0xFC, modulo 0x100.
    public static func checksum(_ body: ArraySlice<UInt8>) -> UInt8 {
        let sum = body.prefix(20).reduce(0) { $0 + Int($1) }
        return UInt8((0x100 - sum % 0x100) % 0x100)
    }

    /// Checks start byte, type, header and checksum. Returns (type, group).
    public static func validate(_ data: [UInt8]) throws -> (type: UInt8, group: UInt8) {
        guard data.count >= 22 else { throw FrameError.tooShort }
        guard data[0] == 0xFC, data[1] == 0x62 || data[1] == 0x7B, data[2] == 0x01, data[3] == 0x30, data[4] == 0x10 else {
            throw FrameError.badHeader
        }
        guard let last = data.last, checksum(data[1..<(data.count - 1)]) == last else { throw FrameError.badChecksum }
        return (data[1], data[5])
    }

    /// Builds one sample from all frames. Invalid frames, 0x7B frames and unknown groups
    /// (0x05, …) are skipped; `rejected` counts frames that failed validation.
    public static func sample(frames: [String], at date: Date) -> (sample: LocalSample, used: Int, rejected: Int) {
        var sample = LocalSample(timestamp: date)
        var used = 0
        var rejected = 0
        for hex in frames {
            guard let data = bytes(hex: hex), let (type, group) = try? validate(data) else {
                rejected += 1
                continue
            }
            guard type == 0x62 else { continue }
            switch group {
            case 0x02: applyGeneral(data, to: &sample)
            case 0x03: applySensors(data, to: &sample)
            case 0x04: applyErrors(data, to: &sample)
            case 0x06: applyEnergy(data, to: &sample)
            case 0x09: applySubMode(data, to: &sample)
            default: continue
            }
            used += 1
        }
        return (sample, used, rejected)
    }

    /// Sample from a whole status reply (frames plus adapter fields).
    public static func sample(reply: LocalStatusReply, at date: Date) -> (sample: LocalSample, used: Int, rejected: Int) {
        var result = sample(frames: reply.frames, at: date)
        result.sample.rssi = reply.rssi
        result.sample.adapterVersion = reply.adapterVersion
        result.sample.cloudConnected = reply.cloudConnect.map { $0 == "ON" }
        return result
    }

    // MARK: Groups

    /// 0x02 general state: power, mode, setpoint, fan, vanes.
    static func applyGeneral(_ d: [UInt8], to s: inout LocalSample) {
        s.power = d[8] == 1
        s.setRaw(mode: Int(d[9] & 0x07), fan: Int(d[11]), vaneVertical: Int(d[12]), vaneHorizontal: Int(d[15] & 0x0F))
        s.iSee = d[9] & 0x08 != 0
        s.setTemperature = d[16] != 0 ? (Double(d[16]) - 0x80) / 2 : Double(31 - Int(d[10]))
    }

    /// 0x03 sensors: room (fine, else coarse), outdoor (invalid while the unit is off), second room
    /// sensor, and the 32-bit runtime minutes in bytes 15–18 (pymi `runtime_minutes`).
    static func applySensors(_ d: [UInt8], to s: inout LocalSample) {
        s.roomTemperature = d[11] != 0 ? (Double(d[11]) - 0x80) / 2 : Double(10 + Int(d[8]))
        s.outdoorTemperature = d[10] > 0x01 ? (Double(d[10]) - 0x80) / 2 : nil
        s.roomTemperature2 = d[12] != 0 ? (Double(d[12]) - 0x80) / 2 : nil
        s.runtimeMinutes = d[15...18].reduce(0) { $0 << 8 | Int($1) }
    }

    /// 0x09 operating sub-mode, stage and auto sub-mode. Offsets agree between
    /// MitsubishiCN105ESPHome (payload index 3/4/5 = frame 8/9/10) and pymi (frame 9/10); only
    /// ESPHome names byte 8.
    static func applySubMode(_ d: [UInt8], to s: inout LocalSample) {
        s.subMode = Int(d[8])
        s.stage = Int(d[9])
        s.autoSubMode = Int(d[10])
    }

    /// 0x04 errors: 0x8000 = no error.
    static func applyErrors(_ d: [UInt8], to s: inout LocalSample) {
        s.errorCode = Int(d[9]) << 8 | Int(d[10])
    }

    /// 0x06 energy: compressor Hz, operating, power W, energy counter (0.1 kWh).
    static func applyEnergy(_ d: [UInt8], to s: inout LocalSample) {
        s.compressorHz = Int(d[8])
        s.operating = d[9] != 0
        s.powerW = Int(d[10]) << 8 | Int(d[11])
        s.energyKWh = Double(Int(d[12]) << 8 | Int(d[13])) / 10
    }

    // MARK: Building frames (simulation and tests only; these are status answers, not commands)

    /// A valid 0x62 status frame for `group` with `payload` placed from index 6, zero-filled to 22 bytes.
    package static func frame(group: UInt8, payload: [Int: UInt8]) -> String {
        var data = [UInt8](repeating: 0, count: 22)
        data[0] = 0xFC
        data[1] = 0x62
        data[2] = 0x01
        data[3] = 0x30
        data[4] = 0x10
        data[5] = group
        for (index, value) in payload where (6..<21).contains(index) { data[index] = value }
        data[21] = checksum(data[1..<21])
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
