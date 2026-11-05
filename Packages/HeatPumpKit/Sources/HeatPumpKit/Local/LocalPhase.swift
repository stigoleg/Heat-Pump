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

    /// Short Norwegian status line for Oversikt.
    public var statusLine: String {
        switch self {
        case .off: "Av"
        case .defrost: "Avriser – det kan blåse lite eller kaldt i noen minutter"
        case .preheat: "Forvarmer"
        case .warmup: "Starter opp"
        case .standby, .resting: "Hviler (ønsket temperatur nådd)"
        case .heating: "Varmer"
        case .cooling: "Kjøler"
        case .drying: "Avfukter"
        case .fan: "Bare vifte"
        case .running: "Går (auto)"
        }
    }

    /// Plain explanation for a non-expert.
    public var explanation: String {
        switch self {
        case .off: "Varmepumpen er slått av."
        case .defrost:
            "Utedelen smelter bort is som har samlet seg. Imens kommer det lite eller kald luft fra innedelen. Det er helt normalt i kaldt og fuktig vær og tar vanligvis 3–10 minutter."
        case .preheat: "Innedelen varmes opp før viften starter for fullt, så den ikke blåser kald luft."
        case .warmup: "Varmepumpen har nettopp startet og kommer i gang."
        case .standby, .resting:
            "Kompressoren står fordi rommet er varmt nok. Den starter igjen av seg selv når temperaturen faller."
        case .heating: "Kompressoren går og varmer rommet."
        case .cooling: "Kompressoren går og kjøler rommet."
        case .drying: "Varmepumpen tar fukt ut av lufta."
        case .fan: "Bare viften går; varmepumpen varmer eller kjøler ikke."
        case .running: "Kompressoren går i automatisk modus."
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
            case .off: "Av"
            case .defrost: "Avriser"
            case .startup: "Starter/forvarmer"
            case .rest: "Hviler"
            case .running: "Går"
            case .unknown: "Ukjent"
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
