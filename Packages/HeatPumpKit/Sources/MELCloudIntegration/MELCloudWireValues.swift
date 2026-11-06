import Foundation
import HeatPumpKit

// MELCloud Classic's numbers for the core's device values, and its device ids inside keys.

extension OperationMode {
    /// MELCloud Classic `OperationMode` (1 heat, 2 dry, 3 cool, 7 fan, 8 auto; 9–11 are i-See,
    /// see `CloudOperationMode`).
    var melcloudValue: Int {
        switch self {
        case .heat: 1
        case .dry: 2
        case .cool: 3
        case .fan: 7
        case .auto: 8
        }
    }

    init?(melcloudValue: Int) {
        guard let mode = Self.allCases.first(where: { $0.melcloudValue == melcloudValue }) else { return nil }
        self = mode
    }
}

extension VaneVertical {
    /// MELCloud Classic `VaneVertical` (0 auto, 1–5, 7 swing).
    var melcloudValue: Int {
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

    init?(melcloudValue: Int) {
        guard let vane = Self.allCases.first(where: { $0.melcloudValue == melcloudValue }) else { return nil }
        self = vane
    }
}

extension VaneHorizontal {
    /// MELCloud Classic `VaneHorizontal` (0 auto, 1–5, 8 split, 12 swing).
    var melcloudValue: Int {
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

    init?(melcloudValue: Int) {
        guard let vane = Self.allCases.first(where: { $0.melcloudValue == melcloudValue }) else { return nil }
        self = vane
    }
}

extension DeviceKey {
    /// The key of MELCloud device `id`: `melcloud-classic:<DeviceID>`.
    static func melcloud(_ id: Int) -> DeviceKey { DeviceKey(integration: MELCloudIntegration.id, nativeId: String(id)) }

    /// MELCloud's `DeviceID` inside the key (any integration's key with a numeric native id, so
    /// the demo's simulated MELCloud unit works too).
    var melcloudDeviceId: Int? { Int(nativeId) }
}

extension DeviceSummary {
    /// Metadata key for MELCloud's `BuildingID` (needed for `Device/Get`, shown by `get_device_info`).
    static let buildingIdKey = "buildingId"
}
