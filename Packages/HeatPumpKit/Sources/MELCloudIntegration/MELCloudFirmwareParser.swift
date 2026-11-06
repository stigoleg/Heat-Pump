import Foundation
import HeatPumpKit

/// Firmware updates of the Wi-Fi adapter (MELCloud Classic). Reverse-engineered from MELCloud's own
/// web client and not verified against the user's account: parsing is tolerant and response shapes
/// (keys and types only) are logged to stderr.
///
/// - `POST FirmwareUpdate/List2` with a JSON array of device ids → array of `{ID, Device, CurrentPhase,
///   CurrentApprovalStatus, MinutesOffline, FilesDownloaded, FilesToDownload, Retries, DateApproved,
///   DateCreated, LastCommunication}` (dates are MELCloud local timestamps).
/// - `POST FirmwareUpdate/Approve2` and `FirmwareUpdate/Cancel2` with `{"id": <status ID>, "deviceid": <device id>}`.
extension MELCloudClassicParser {
    static func firmwareListBody(deviceId: Int) -> JSONValue {
        .array([.number(Double(deviceId))])
    }

    /// Body for Approve2 and Cancel2 (lower-case keys, as the web client sends them).
    static func firmwareActionBody(id: Int, deviceId: Int) -> JSONValue {
        .object(["id": .number(Double(id)), "deviceid": .number(Double(deviceId))])
    }

    /// Entries of a List2 answer. Anything that is not an object is skipped; missing fields stay nil.
    /// An object instead of an array is read as a single entry.
    static func firmwareUpdates(_ json: JSONValue, timeZone: TimeZone) -> [FirmwareUpdateStatus] {
        let entries = json.array ?? (json.object != nil ? [json] : [])
        return entries.compactMap { entry in
            guard entry.object != nil else { return nil }
            func date(_ key: String) -> Date? { WireDate.parse(entry[key]?.string, timeZone: timeZone) }
            return FirmwareUpdateStatus(
                id: entry["ID"]?.int, device: (entry["Device"]?.int ?? entry["DeviceID"]?.int).map(DeviceKey.melcloud),
                currentPhase: entry["CurrentPhase"]?.int, approvalStatus: entry["CurrentApprovalStatus"]?.int,
                minutesOffline: entry["MinutesOffline"]?.int, filesDownloaded: entry["FilesDownloaded"]?.int,
                filesToDownload: entry["FilesToDownload"]?.int, retries: entry["Retries"]?.int,
                dateApproved: date("DateApproved"), dateCreated: date("DateCreated"), lastCommunication: date("LastCommunication"))
        }
    }
}
