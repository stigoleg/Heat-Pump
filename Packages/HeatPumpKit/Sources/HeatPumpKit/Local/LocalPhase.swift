import Foundation

/// What the unit is doing right now, from the local 0x09 sub-mode and the compressor state.
public enum LocalPhase: String, Codable, Sendable, CaseIterable {
    case off
    case defrost
    case preheat
    case warmup
    case standby
    case resting
    case heating
    case cooling
    case drying
    case fan
    case running

    /// Short status line for Overview.
    public var statusLine: String {
        switch self {
        case .off: L10n.tr("Off")
        case .defrost: L10n.tr("Defrosting – it may blow little or cold air for a few minutes")
        case .preheat: L10n.tr("Pre-heating")
        case .warmup: L10n.tr("Starting up")
        case .standby, .resting: L10n.tr("Resting – the compressor is idle")
        case .heating: L10n.tr("Heating")
        case .cooling: L10n.tr("Cooling")
        case .drying: L10n.tr("Drying")
        case .fan: L10n.tr("Fan only")
        case .running: L10n.tr("Running (auto)")
        }
    }

    /// Plain explanation for a non-expert.
    public var explanation: String {
        switch self {
        case .off: L10n.tr("The heat pump is turned off.")
        case .defrost:
            L10n.tr("The outdoor unit is melting away ice that has built up. Meanwhile little or cold air comes from the indoor unit. This is perfectly normal in cold, damp weather and usually takes 3–10 minutes.")
        case .preheat: L10n.tr("The indoor unit warms up before the fan starts in earnest, so it does not blow cold air.")
        case .warmup: L10n.tr("The heat pump has just started and is getting going.")
        case .standby, .resting:
            L10n.tr("The compressor is idle. This happens when the room is warm enough, and otherwise for a short while between two runs. It starts again by itself.")
        case .heating: L10n.tr("The compressor is running and heating the room.")
        case .cooling: L10n.tr("The compressor is running and cooling the room.")
        case .drying: L10n.tr("The heat pump is taking moisture out of the air.")
        case .fan: L10n.tr("Only the fan is running; the heat pump is not heating or cooling.")
        case .running: L10n.tr("The compressor is running in automatic mode.")
        }
    }

    public var systemImage: String {
        switch self {
        case .off: "power"
        case .defrost: "snowflake"
        case .preheat, .warmup: "flame"
        case .standby, .resting: "pause.circle"
        case .heating: "flame.fill"
        case .cooling: "snowflake.circle"
        case .drying: "drop.fill"
        case .fan: "fan"
        case .running: "arrow.triangle.2.circlepath"
        }
    }

    /// Band the phase belongs to in charts.
    public var spanKind: LocalPhaseSpan.Kind {
        switch self {
        case .off: .off
        case .defrost: .defrost
        case .preheat, .warmup: .startup
        case .standby, .resting: .rest
        case .heating, .cooling, .drying, .fan, .running: .running
        }
    }
}

/// A stretch of time with the same kind of operation, from local readings.
public struct LocalPhaseSpan: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case off, defrost, startup, rest, running, unknown

        public var displayName: String {
            switch self {
            case .off: L10n.tr("Off")
            case .defrost: L10n.tr("Defrosting")
            case .startup: L10n.tr("Starting/pre-heating")
            case .rest: L10n.tr("Resting")
            case .running: L10n.tr("Running")
            case .unknown: L10n.tr("Unknown")
            }
        }
    }

    public var kind: Kind
    public var start: Date
    public var end: Date

    public init(kind: Kind, start: Date, end: Date) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}
