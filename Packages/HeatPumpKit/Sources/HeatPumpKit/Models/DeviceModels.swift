import Foundation

/// Air-to-air operation mode. The raw value is the stable `key`; integrations map their wire
/// values in their own module.
public enum OperationMode: String, Sendable, CaseIterable {
    case heat
    case dry
    case cool
    case fan
    case auto

    /// Display name ("Heat").
    public var displayName: String {
        switch self {
        case .heat: L10n.tr("Heat")
        case .dry: L10n.tr("Dry")
        case .cool: L10n.tr("Cool")
        case .fan: L10n.tr("Fan")
        case .auto: L10n.tr("Auto")
        }
    }

    /// The name inside a sentence ("heat"); its own key, since lowercasing `displayName` is not
    /// right in every language.
    public var sentenceName: String {
        switch self {
        case .heat: L10n.tr("heat")
        case .dry: L10n.tr("dry")
        case .cool: L10n.tr("cool")
        case .fan: L10n.tr("fan")
        case .auto: L10n.tr("auto")
        }
    }

    /// Stable machine name used by the MCP tools (and the persisted raw value).
    public var key: String { rawValue }

    public init?(key: String) {
        guard let mode = Self.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = mode
    }

    /// The integer stored before v12 (snapshots, settings JSON). Also the number the history
    /// chart and the MCP tools (`get_history`, `get_energy`) have always shown for a mode.
    public var legacyCode: Int {
        switch self {
        case .heat: 1
        case .dry: 2
        case .cool: 3
        case .fan: 7
        case .auto: 8
        }
    }
}

extension OperationMode: Codable {
    public init(from decoder: any Decoder) throws {
        self = try decodeDeviceEnum(decoder)
    }
}

/// Vertical vane position. The raw value is the stable `key`.
public enum VaneVertical: String, Sendable, CaseIterable {
    case auto
    case position1 = "1_up"
    case position2 = "2"
    case position3 = "3"
    case position4 = "4"
    case position5 = "5_down"
    case swing

    public var key: String { rawValue }

    /// 1 (top) … 5 (bottom) for a fixed position, nil for auto and swing.
    public var position: Int? {
        switch self {
        case .position1: 1
        case .position2: 2
        case .position3: 3
        case .position4: 4
        case .position5: 5
        case .auto, .swing: nil
        }
    }

    /// The integer stored before v12.
    public var legacyCode: Int {
        switch self {
        case .auto: 0
        case .position1: 1
        case .position2: 2
        case .position3: 3
        case .position4: 4
        case .position5: 5
        case .swing: 7
        }
    }

    public var displayName: String {
        switch self {
        case .auto: L10n.tr("Auto")
        case .position1: L10n.tr("1 (top)")
        case .position2: "2"
        case .position3: "3"
        case .position4: "4"
        case .position5: L10n.tr("5 (bottom)")
        case .swing: L10n.tr("Swing")
        }
    }

    public init?(key: String) {
        guard let value = Self.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = value
    }
}

extension VaneVertical: Codable {
    public init(from decoder: any Decoder) throws {
        self = try decodeDeviceEnum(decoder)
    }
}

/// Horizontal vane position. The raw value is the stable `key`.
public enum VaneHorizontal: String, Sendable, CaseIterable {
    case auto
    case position1 = "1_left"
    case position2 = "2"
    case position3 = "3"
    case position4 = "4"
    case position5 = "5_right"
    case split
    case swing

    public var key: String { rawValue }

    /// 1 (left) … 5 (right) for a fixed position, nil for auto, split and swing.
    public var position: Int? {
        switch self {
        case .position1: 1
        case .position2: 2
        case .position3: 3
        case .position4: 4
        case .position5: 5
        case .auto, .split, .swing: nil
        }
    }

    /// The integer stored before v12.
    public var legacyCode: Int {
        switch self {
        case .auto: 0
        case .position1: 1
        case .position2: 2
        case .position3: 3
        case .position4: 4
        case .position5: 5
        case .split: 8
        case .swing: 12
        }
    }

    public var displayName: String {
        switch self {
        case .auto: L10n.tr("Auto")
        case .position1: L10n.tr("1 (left)")
        case .position2: "2"
        case .position3: L10n.tr("3 (center)")
        case .position4: "4"
        case .position5: L10n.tr("5 (right)")
        case .split: L10n.tr("Split")
        case .swing: L10n.tr("Swing")
        }
    }

    public init?(key: String) {
        guard let value = Self.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = value
    }
}

extension VaneHorizontal: Codable {
    public init(from decoder: any Decoder) throws {
        self = try decodeDeviceEnum(decoder)
    }
}

/// A device enum stored by its key since v12, and as an integer before.
protocol LegacyCodedEnum: RawRepresentable<String>, CaseIterable {
    var legacyCode: Int { get }
}

extension OperationMode: LegacyCodedEnum {}
extension VaneVertical: LegacyCodedEnum {}
extension VaneHorizontal: LegacyCodedEnum {}

/// Decodes the key, or the integer that settings JSON, snapshots and caches written before v12
/// hold, so they keep decoding.
private func decodeDeviceEnum<T: LegacyCodedEnum>(_ decoder: any Decoder) throws -> T {
    let container = try decoder.singleValueContainer()
    if let key = try? container.decode(String.self), let value = T(rawValue: key) { return value }
    if let code = try? container.decode(Int.self), let value = T.allCases.first(where: { $0.legacyCode == code }) {
        return value
    }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown \(T.self) value")
}

/// Setpoint limits per mode, as reported by the device.
public struct TemperatureLimits: Codable, Sendable, Equatable {
    public var minHeat: Double
    public var maxHeat: Double
    public var minCoolDry: Double
    public var maxCoolDry: Double
    public var minAuto: Double
    public var maxAuto: Double

    public init(
        minHeat: Double = 10, maxHeat: Double = 31,
        minCoolDry: Double = 16, maxCoolDry: Double = 31,
        minAuto: Double = 16, maxAuto: Double = 31
    ) {
        self.minHeat = minHeat
        self.maxHeat = maxHeat
        self.minCoolDry = minCoolDry
        self.maxCoolDry = maxCoolDry
        self.minAuto = minAuto
        self.maxAuto = maxAuto
    }

    /// Allowed setpoints for a mode. Falls back to the MELCloud defaults when the device
    /// reports nonsense (non-finite, min above max, e.g. `MaxTempAutomatic` = 0).
    public func range(for mode: OperationMode) -> ClosedRange<Double> {
        let fallback = Self.defaults(for: mode)
        let (low, high): (Double, Double) =
            switch mode {
            case .heat, .fan: (minHeat, maxHeat)
            case .cool, .dry: (minCoolDry, maxCoolDry)
            case .auto: (minAuto, maxAuto)
            }
        guard low.isFinite, high.isFinite, low < high, low >= 0, high <= 40 else { return fallback }
        return low...high
    }

    static func defaults(for mode: OperationMode) -> ClosedRange<Double> {
        switch mode {
        case .heat, .fan: 10...31
        case .cool, .dry, .auto: 16...31
        }
    }
}

public struct FirmwareInfo: Codable, Sendable, Equatable {
    /// MELCloud's id of a firmware deployment queued for the Wi-Fi adapter (an internal number,
    /// not a version; never shown to the user). Non-empty means an update is available.
    public var deployment: String?
    public var updateAborted: Bool
    public var adaptorType: Int?
    /// `FirmwareAppVersion` as reported, e.g. 34000 for version 34.00.
    public var appVersion: Int?
    /// `WifiAdapterStatus`, e.g. "NORMAL".
    public var adapterStatus: String?
    /// `AccessLevel` from the device listing (4 = owner; only owners may start a firmware update).
    public var accessLevel: Int?

    public init(
        deployment: String? = nil, updateAborted: Bool = false, adaptorType: Int? = nil, appVersion: Int? = nil,
        adapterStatus: String? = nil, accessLevel: Int? = nil
    ) {
        self.deployment = deployment
        self.updateAborted = updateAborted
        self.adaptorType = adaptorType
        self.appVersion = appVersion
        self.adapterStatus = adapterStatus
        self.accessLevel = accessLevel
    }

    public static let ownerAccessLevel = 4

    /// True when the account owns the unit, nil when the listing did not say.
    public var isOwner: Bool? { accessLevel.map { $0 == Self.ownerAccessLevel } }

    /// Adapter firmware version as shown in MELCloud, e.g. "34.00" (nil when unknown or 0).
    public var version: String? {
        guard let appVersion, appVersion > 0 else { return nil }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(appVersion) / 1000)
    }

    /// True when MELCloud has a newer adapter firmware ready.
    public var updateAvailable: Bool { !(deployment ?? "").isEmpty }
}

/// Energy counters in kWh (nil when the device has no meter).
public struct EnergyCounters: Codable, Sendable, Equatable {
    public var currentConsumedKWh: Double?
    public var totalHeatingKWh: Double?
    public var totalCoolingKWh: Double?
    public var totalAutoKWh: Double?
    public var totalDryKWh: Double?
    public var totalFanKWh: Double?
    /// When `currentConsumedKWh` was read. MELCloud only reports it in the device listing,
    /// which is cached for up to 30 minutes, so this can be older than the snapshot.
    public var counterAt: Date?

    public init(
        currentConsumedKWh: Double? = nil, totalHeatingKWh: Double? = nil, totalCoolingKWh: Double? = nil,
        totalAutoKWh: Double? = nil, totalDryKWh: Double? = nil, totalFanKWh: Double? = nil, counterAt: Date? = nil
    ) {
        self.counterAt = counterAt
        self.currentConsumedKWh = currentConsumedKWh
        self.totalHeatingKWh = totalHeatingKWh
        self.totalCoolingKWh = totalCoolingKWh
        self.totalAutoKWh = totalAutoKWh
        self.totalDryKWh = totalDryKWh
        self.totalFanKWh = totalFanKWh
    }
}

/// Backend-neutral snapshot of one indoor unit.
public struct DeviceState: Codable, Sendable, Equatable {
    public var key: DeviceKey
    public var name: String
    public var serialNumber: String?
    public var macAddress: String?

    public var power: Bool
    public var mode: OperationMode?
    /// True when MELCloud reports the mode with i-See (OperationMode 9/10/11); nil when unknown.
    public var iSee: Bool?
    public var setTemperature: Double?
    public var roomTemperature: Double?
    public var outdoorTemperature: Double?
    /// 0 = auto, 1…numberOfFanSpeeds.
    public var fanSpeed: Int?
    public var actualFanSpeed: Int?
    public var numberOfFanSpeeds: Int
    public var hasAutomaticFanSpeed: Bool
    public var vaneVertical: VaneVertical?
    public var vaneHorizontal: VaneHorizontal?

    public var hasError: Bool
    public var errorCode: Int?
    public var offline: Bool
    public var lastCommunication: Date?
    public var nextCommunication: Date?
    /// Wi-Fi RSSI in dBm (negative) as reported by MELCloud.
    public var wifiSignal: Int?
    public var hasPendingCommand: Bool

    public var firmware: FirmwareInfo
    public var lastServiceDate: Date?
    public var energy: EnergyCounters
    public var limits: TemperatureLimits
    public var temperatureIncrement: Double

    /// When this snapshot was fetched from the backend.
    public var fetchedAt: Date

    public init(
        key: DeviceKey, name: String, serialNumber: String? = nil, macAddress: String? = nil,
        power: Bool, mode: OperationMode?, iSee: Bool? = nil, setTemperature: Double?, roomTemperature: Double?,
        outdoorTemperature: Double? = nil, fanSpeed: Int? = nil, actualFanSpeed: Int? = nil,
        numberOfFanSpeeds: Int = 5, hasAutomaticFanSpeed: Bool = true,
        vaneVertical: VaneVertical? = nil, vaneHorizontal: VaneHorizontal? = nil,
        hasError: Bool = false, errorCode: Int? = nil, offline: Bool = false,
        lastCommunication: Date? = nil, nextCommunication: Date? = nil, wifiSignal: Int? = nil,
        hasPendingCommand: Bool = false, firmware: FirmwareInfo = FirmwareInfo(), lastServiceDate: Date? = nil,
        energy: EnergyCounters = EnergyCounters(), limits: TemperatureLimits = TemperatureLimits(),
        temperatureIncrement: Double = 0.5, fetchedAt: Date
    ) {
        self.key = key
        self.name = name
        self.serialNumber = serialNumber
        self.macAddress = macAddress
        self.power = power
        self.mode = mode
        self.iSee = iSee
        self.setTemperature = setTemperature
        self.roomTemperature = roomTemperature
        self.outdoorTemperature = outdoorTemperature
        self.fanSpeed = fanSpeed
        self.actualFanSpeed = actualFanSpeed
        self.numberOfFanSpeeds = numberOfFanSpeeds
        self.hasAutomaticFanSpeed = hasAutomaticFanSpeed
        self.vaneVertical = vaneVertical
        self.vaneHorizontal = vaneHorizontal
        self.hasError = hasError
        self.errorCode = errorCode
        self.offline = offline
        self.lastCommunication = lastCommunication
        self.nextCommunication = nextCommunication
        self.wifiSignal = wifiSignal
        self.hasPendingCommand = hasPendingCommand
        self.firmware = firmware
        self.lastServiceDate = lastServiceDate
        self.energy = energy
        self.limits = limits
        self.temperatureIncrement = temperatureIncrement
        self.fetchedAt = fetchedAt
    }

    /// True when the unit reports an error: the error flag, or a code outside `noErrorCodes`
    /// (the integration's "no error" codes, `ErrorCodeExplaining.noErrorCodes`).
    public func hasActiveError(noErrorCodes: Set<Int>) -> Bool {
        if hasError { return true }
        if let errorCode, !noErrorCodes.contains(errorCode) { return true }
        return false
    }

    /// The unit's setpoint step (0.5 °C when it reports none).
    public var setpointIncrement: Double { temperatureIncrement > 0 ? temperatureIncrement : 0.5 }

    /// `celsius` rounded to the unit's setpoint step, as a change is sent.
    public func snappedSetpoint(_ celsius: Double) -> Double {
        (celsius / setpointIncrement).rounded() * setpointIncrement
    }
}

/// Minimal identity of a device, as listed by a backend.
public struct DeviceSummary: Codable, Sendable, Equatable {
    public var key: DeviceKey
    public var name: String
    public var kind: DeviceKind
    /// Integration-defined attributes kept in the device registry (`devices.metadata`), e.g. the
    /// building a cloud account files the unit under. Only the integration interprets them.
    public var metadata: [String: String]

    public init(key: DeviceKey, name: String, kind: DeviceKind = .airToAirHeatPump, metadata: [String: String] = [:]) {
        self.key = key
        self.name = name
        self.kind = kind
        self.metadata = metadata
    }
}

/// A requested change. Only non-nil fields are sent.
public struct ChangeSet: Sendable, Equatable {
    public var device: DeviceKey
    public var power: Bool?
    public var mode: OperationMode?
    public var setTemperature: Double?
    public var fanSpeed: Int?
    public var vaneVertical: VaneVertical?
    public var vaneHorizontal: VaneHorizontal?

    public init(
        device: DeviceKey, power: Bool? = nil, mode: OperationMode? = nil,
        setTemperature: Double? = nil, fanSpeed: Int? = nil,
        vaneVertical: VaneVertical? = nil, vaneHorizontal: VaneHorizontal? = nil
    ) {
        self.device = device
        self.power = power
        self.mode = mode
        self.setTemperature = setTemperature
        self.fanSpeed = fanSpeed
        self.vaneVertical = vaneVertical
        self.vaneHorizontal = vaneHorizontal
    }
}

/// One user-level change, as requested by the app or by Claude.
public enum DeviceChange: Sendable, Equatable {
    case power(Bool)
    case mode(OperationMode)
    case temperature(Double)
    case fanSpeed(Int)
    case vaneVertical(VaneVertical)
    case vaneHorizontal(VaneHorizontal)

    /// Field name logged in `change_log`.
    public var field: String {
        switch self {
        case .power: "power"
        case .mode: "mode"
        case .temperature: "setTemperature"
        case .fanSpeed: "fanSpeed"
        case .vaneVertical: "vaneVertical"
        case .vaneHorizontal: "vaneHorizontal"
        }
    }

    public var valueDescription: String {
        switch self {
        case .power(let on): on ? "on" : "off"
        case .mode(let mode): mode.key
        case .temperature(let celsius): String(format: "%.1f", celsius)
        case .fanSpeed(let speed): speed == 0 ? "auto" : String(speed)
        case .vaneVertical(let vane): vane.key
        case .vaneHorizontal(let vane): vane.key
        }
    }

    /// One-line summary for confirmations.
    public var displaySummary: String {
        switch self {
        case .power(let on): on ? L10n.tr("Turn the heat pump ON") : L10n.tr("Turn the heat pump OFF")
        case .mode(let mode): L10n.format("Change mode to %@", mode.displayName)
        case .temperature(let celsius): L10n.format("Change target temperature to %.1f °C", celsius)
        case .fanSpeed(let speed): speed == 0 ? L10n.tr("Set fan speed to auto") : L10n.format("Set fan speed to %lld", speed)
        case .vaneVertical(let vane): L10n.format("Set vertical airflow to %@", vane.displayName)
        case .vaneHorizontal(let vane): L10n.format("Set horizontal airflow to %@", vane.displayName)
        }
    }

    /// `state` with this change applied (what MELCloud should report after it is accepted).
    public func applied(to state: DeviceState) -> DeviceState {
        var next = state
        switch self {
        case .power(let on): next.power = on
        case .mode(let mode):
            next.mode = mode
            next.iSee = nil  // the plain value is sent; whether i-See stays on is up to the unit
        case .temperature(let celsius): next.setTemperature = celsius
        case .fanSpeed(let speed): next.fanSpeed = speed
        case .vaneVertical(let vane): next.vaneVertical = vane
        case .vaneHorizontal(let vane): next.vaneHorizontal = vane
        }
        return next
    }

    var isVane: Bool {
        switch self {
        case .vaneVertical, .vaneHorizontal: true
        default: false
        }
    }

    /// Order used when validating a batch: mode before setpoint, so the setpoint is checked
    /// against the mode that will be active.
    var validationOrder: Int {
        switch self {
        case .power: 0
        case .mode: 1
        case .fanSpeed: 2
        case .vaneVertical: 3
        case .vaneHorizontal: 4
        case .temperature: 5
        }
    }

    /// Current value of this field in a state, for logging old → new.
    public func currentValue(in state: DeviceState?) -> String? {
        guard let state else { return nil }
        switch self {
        case .power: return state.power ? "on" : "off"
        case .mode: return state.mode?.key
        case .temperature: return state.setTemperature.map { String(format: "%.1f", $0) }
        case .fanSpeed: return state.fanSpeed.map { $0 == 0 ? "auto" : String($0) }
        case .vaneVertical: return state.vaneVertical?.key
        case .vaneHorizontal: return state.vaneHorizontal?.key
        }
    }
}
