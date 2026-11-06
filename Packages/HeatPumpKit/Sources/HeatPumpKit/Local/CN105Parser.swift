import Foundation

/// One local reading from the Wi-Fi adapter (CN105 status frames). Contains no identifiers.
public struct LocalSample: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var power: Bool?
    public var mode: OperationMode?
    /// Raw CN105 mode (0 auto, 1 heat, 2 dry, 3 cool, 7 fan).
    public var modeRaw: Int?
    public var iSee: Bool?
    public var setTemperature: Double?
    /// 0 = auto, 1–5 like MELCloud; nil when the raw value is unknown.
    public var fanSpeed: Int?
    public var fanRaw: Int?
    public var vaneVertical: VaneVertical?
    public var vaneVerticalRaw: Int?
    public var vaneHorizontal: VaneHorizontal?
    public var vaneHorizontalRaw: Int?
    public var roomTemperature: Double?
    /// Second indoor sensor (moves differently from the main one; shown for analysis only).
    public var roomTemperature2: Double?
    public var outdoorTemperature: Double?
    public var compressorHz: Int?
    public var operating: Bool?
    /// Electrical power of the whole unit in W.
    public var powerW: Int?
    /// Lifetime energy counter in kWh (0.1 kWh steps, 16-bit: wraps after 6553.5 kWh).
    public var energyKWh: Double?
    /// CN105 error code; 0x8000 means no error.
    public var errorCode: Int?
    public var rssi: Int?
    public var adapterVersion: String?
    /// False when the adapter reports `CONNECT=OFF` (MELCloud connection switched off in the adapter).
    public var cloudConnected: Bool?
    /// 0x09 byte 8: 0 normal, 1 warm-up, 2 defrost, 4 preheat, 8 standby, 0x10 off (MitsubishiCN105ESPHome).
    public var subMode: Int?
    /// 0x09 byte 9: demand stage, 0 idle … 5 high, 6 diffuse (names uncertain; pymi calls it "power mode").
    public var stage: Int?
    /// 0x09 byte 10: auto sub-mode. Sources disagree on the meaning of 1 and 3 (ESPHome: 1 cool,
    /// 3 leader; pymi: 1 switching, 3 auto cooling); 0 off and 2 heat agree. Shown raw, marked uncertain.
    public var autoSubMode: Int?
    /// 0x03 bytes 15–18: minutes counter from the indoor unit (big-endian). Most likely total
    /// powered/operating time; labelled as the indoor unit's own figure.
    public var runtimeMinutes: Int?

    public init(timestamp: Date) {
        self.timestamp = timestamp
    }

    /// The compressor is running (operating flag, or a non-zero frequency).
    public var isRunning: Bool { operating == true || (compressorHz ?? 0) > 0 }

    var hasCompressorData: Bool { operating != nil || compressorHz != nil }

    /// True when the error code says something is wrong.
    public var hasError: Bool { errorCode.map { $0 != CN105Parser.noError } ?? false }

    /// Whole hours of the indoor unit's runtime counter.
    public var runtimeHours: Int? { runtimeMinutes.map { $0 / 60 } }

    /// Status line for this reading: "Resting (target temperature reached)" only when the room really is
    /// at or above the setpoint, otherwise the neutral phase text.
    public var statusLine: String? {
        guard let phase else { return nil }
        if phase == .standby || phase == .resting, let room = roomTemperature, let set = setTemperature, room >= set {
            return L10n.tr("Resting (target temperature reached)")
        }
        return phase.statusLine
    }

    /// What the unit is doing (defrost, standby, heating …), or nil without enough data.
    public var phase: LocalPhase? {
        if power == false || subMode == 0x10 { return .off }
        switch subMode {
        case 2: return .defrost
        case 4: return .preheat
        case 1: return .warmup
        case 8: return .standby
        default: break
        }
        guard hasCompressorData else { return nil }
        guard isRunning else { return mode == .fan ? .fan : .resting }
        switch mode {
        case .heat: return .heating
        case .cool: return .cooling
        case .dry: return .drying
        case .fan: return .fan
        case .auto, nil: return .running
        }
    }

    /// Sets the raw CN105 values and the MELCloud-style enums they map to (nil when unknown).
    mutating func setRaw(mode: Int?, fan: Int?, vaneVertical: Int?, vaneHorizontal: Int?) {
        modeRaw = mode
        self.mode = mode.flatMap(CN105Parser.mode(raw:))
        fanRaw = fan
        fanSpeed = fan.flatMap(CN105Parser.fanSpeed(raw:))
        vaneVerticalRaw = vaneVertical
        self.vaneVertical = vaneVertical.flatMap(VaneVertical.init(rawValue:))
        vaneHorizontalRaw = vaneHorizontal
        self.vaneHorizontal = vaneHorizontal.flatMap(CN105Parser.vaneHorizontal(raw:))
    }
}

/// Pure decoding of CN105 status frames as returned in the adapter's `<CODE><VALUE>` list.
/// Offsets are full-frame indices (frame[0] = 0xFC).
public enum CN105Parser {
    public static let noError = 0x8000
    /// The 16-bit energy counter in 0.1 kWh wraps after this many kWh.
    public static let counterWrapKWh = 6553.6

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

    static func mode(raw: Int) -> OperationMode? {
        switch raw {
        case 0: .auto
        case 1: .heat
        case 2: .dry
        case 3: .cool
        case 7: .fan
        default: nil
        }
    }

    /// CN105 fan 0 auto, 1/2/3 → 1–3, 5 → 4, 6 → 5 (MELCloud's 0…5).
    static func fanSpeed(raw: Int) -> Int? {
        switch raw {
        case 0, 1, 2, 3: raw
        case 5: 4
        case 6: 5
        default: nil
        }
    }

    /// 6, 7 and 9 are vane combinations MELCloud has no value for; 8 is "split" in both.
    static func vaneHorizontal(raw: Int) -> VaneHorizontal? {
        [6, 7, 9].contains(raw) ? nil : VaneHorizontal(rawValue: raw)
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
    static func frame(group: UInt8, payload: [Int: UInt8]) -> String {
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

/// Energy from the local counter.
public enum LocalCounter {
    /// Longest gap between two readings that is still split over the hours between them as exact.
    public static let maxExactGap: TimeInterval = 2 * 3600

    /// kWh used between two counter readings, handling the 16-bit wrap. Nil when the change is
    /// impossible (more than 3 kW on average, or a counter reset).
    public static func delta(from a: Double, to b: Double, seconds: TimeInterval) -> Double? {
        var d = b - a
        if d < 0 { d += CN105Parser.counterWrapKWh }
        let maxKWh = max(0.2, 3.0 * seconds / 3600)
        guard d >= 0, d <= maxKWh else { return nil }
        return (d * 10).rounded() / 10
    }

    /// Hourly kWh and seconds of each hour covered by readings at most `maxExactGap` apart.
    public static func hourly(_ samples: [(at: Date, kWh: Double)], timeZone: TimeZone) -> [Date: (kWh: Double, covered: TimeInterval)] {
        let sorted = samples.sorted { $0.at < $1.at }
        let calendar = WireDate.calendar(timeZone)
        var result: [Date: (kWh: Double, covered: TimeInterval)] = [:]
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let span = b.at.timeIntervalSince(a.at)
            guard span > 0, span <= maxExactGap, let delta = delta(from: a.kWh, to: b.kWh, seconds: span) else { continue }
            var cursor = a.at
            while cursor < b.at {
                guard let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start else { break }
                let end = min(hourStart.addingTimeInterval(3600), b.at)
                let part = end.timeIntervalSince(cursor)
                let old = result[hourStart] ?? (0, 0)
                result[hourStart] = (old.kWh + delta * part / span, old.covered + part)
                cursor = end
            }
        }
        return result
    }
}

/// Compressor starts per hour.
public struct HourStarts: Codable, Sendable, Equatable {
    public var hour: Date
    public var starts: Int
    /// Minutes of the hour covered by readings close enough together to see a start.
    public var observedMinutes: Double

    public init(hour: Date, starts: Int, observedMinutes: Double) {
        self.hour = hour
        self.starts = starts
        self.observedMinutes = observedMinutes
    }
}

public enum CompressorCycles {
    /// Readings further apart than this are not compared (a start could be missed or invented).
    public static let maxGap: TimeInterval = 5 * 60

    /// Starts and observed seconds over all consecutive readings ≤ `maxGap` apart.
    public static func starts(in samples: [LocalSample]) -> (starts: Int, observed: TimeInterval) {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var starts = 0
        var observed: TimeInterval = 0
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timestamp.timeIntervalSince(a.timestamp)
            guard gap > 0, gap <= maxGap, a.hasCompressorData, b.hasCompressorData else { continue }
            observed += gap
            if !a.isRunning && b.isRunning { starts += 1 }
        }
        return (starts, observed)
    }

    /// Seconds the compressor ran, from readings ≤ `maxGap` apart (state of the earlier reading).
    public static func runningSeconds(in samples: [LocalSample]) -> TimeInterval {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            return gap > 0 && gap <= maxGap && pair.0.isRunning ? total + gap : total
        }
    }

    /// Counts starts (stopped → running) between consecutive readings, per hour of the later reading.
    public static func startsPerHour(_ samples: [LocalSample], timeZone: TimeZone) -> [HourStarts] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let calendar = WireDate.calendar(timeZone)
        var starts: [Date: Int] = [:]
        var observed: [Date: TimeInterval] = [:]
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timestamp.timeIntervalSince(a.timestamp)
            guard gap > 0, gap <= maxGap, a.hasCompressorData, b.hasCompressorData,
                let hour = calendar.dateInterval(of: .hour, for: b.timestamp)?.start
            else { continue }
            observed[hour, default: 0] += gap
            starts[hour, default: 0] += (!a.isRunning && b.isRunning) ? 1 : 0
        }
        return observed.keys.sorted().map {
            HourStarts(hour: $0, starts: starts[$0] ?? 0, observedMinutes: min(60, (observed[$0] ?? 0) / 60))
        }
    }
}
