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

    /// `errorCode` meaning no error.
    public static let noErrorCode = 0x8000
    /// The 16-bit energy counter in 0.1 kWh wraps after this many kWh.
    public static let counterWrapKWh = 6553.6

    /// The compressor is running (operating flag, or a non-zero frequency).
    public var isRunning: Bool { operating == true || (compressorHz ?? 0) > 0 }

    var hasCompressorData: Bool { operating != nil || compressorHz != nil }

    /// True when the error code says something is wrong.
    public var hasError: Bool { errorCode.map { $0 != Self.noErrorCode } ?? false }

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

    /// Sets the raw CN105 values and the MELCloud-style enums they map to (nil when unknown). Kept
    /// with the sample because the store keeps the raw values and maps them when it reads.
    package mutating func setRaw(mode: Int?, fan: Int?, vaneVertical: Int?, vaneHorizontal: Int?) {
        modeRaw = mode
        self.mode = mode.flatMap(Self.mode(raw:))
        fanRaw = fan
        fanSpeed = fan.flatMap(Self.fanSpeed(raw:))
        vaneVerticalRaw = vaneVertical
        self.vaneVertical = vaneVertical.flatMap(Self.vaneVertical(raw:))
        vaneHorizontalRaw = vaneHorizontal
        self.vaneHorizontal = vaneHorizontal.flatMap(Self.vaneHorizontal(raw:))
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

    /// CN105 vertical vane: 0 auto, 1–5, 7 swing.
    static func vaneVertical(raw: Int) -> VaneVertical? {
        switch raw {
        case 0: .auto
        case 1: .position1
        case 2: .position2
        case 3: .position3
        case 4: .position4
        case 5: .position5
        case 7: .swing
        default: nil
        }
    }

    /// CN105 horizontal vane: 0 auto, 1–5, 8 split, 12 swing. 6, 7 and 9 are vane combinations
    /// MELCloud has no value for.
    static func vaneHorizontal(raw: Int) -> VaneHorizontal? {
        switch raw {
        case 0: .auto
        case 1: .position1
        case 2: .position2
        case 3: .position3
        case 4: .position4
        case 5: .position5
        case 8: .split
        case 12: .swing
        default: nil
        }
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
        if d < 0 { d += LocalSample.counterWrapKWh }
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
