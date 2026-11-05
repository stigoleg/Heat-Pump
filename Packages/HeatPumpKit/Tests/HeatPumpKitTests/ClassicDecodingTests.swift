import Foundation
import Testing
@testable import HeatPumpKit

@Suite("MELCloud Classic decoding")
struct ClassicDecodingTests {
    let now = Date(timeIntervalSince1970: 1_793_872_800)
    let utc = TimeZone.gmt

    @Test func loginSuccess() throws {
        let outcome = MELCloudClassicParser.parseLogin(try Fixture.json("login_success"), now: now)
        guard case .success(let key, let expiry) = outcome else { Issue.record("expected success: \(outcome)"); return }
        #expect(key == "FAKE-CONTEXT-KEY-0001")
        #expect(expiry != nil)
    }

    @Test func loginRefused() throws {
        let outcome = MELCloudClassicParser.parseLogin(try Fixture.json("login_refused"), now: now)
        #expect(outcome == .refused(errorId: 1, message: "Feil e-post eller passord"))
    }

    @Test func loginThrottled() throws {
        let outcome = MELCloudClassicParser.parseLogin(try Fixture.json("login_throttled"), now: now)
        #expect(outcome == .throttled(until: now.addingTimeInterval(17 * 60)))
    }

    @Test func listingFlattensHierarchyDedupesAndSkipsNonATA() throws {
        let devices = MELCloudClassicParser.listedDevices(try Fixture.json("list_devices"))
        #expect(devices.count == 1)
        #expect(devices.first?["DeviceName"]?.string == "Stue")
        let summaries = devices.compactMap(MELCloudClassicParser.summary)
        #expect(summaries.map(\.deviceId) == [100001])
        #expect(summaries.first?.buildingId == 200001)
    }

    @Test func stateFromListingOnly() throws {
        let listing = try Fixture.json("list_devices").array?[0]["Structure"]?["Floors"]?.array?[0]["Areas"]?.array?[0]["Devices"]?.array?[0]
        let state = try MELCloudClassicParser.state(listing: listing, get: nil, fetchedAt: now)
        #expect(state.deviceId == 100001)
        #expect(state.buildingId == 200001)
        #expect(state.name == "Stue")
        #expect(state.power)
        #expect(state.mode == .heat)
        #expect(state.setTemperature == 21)
        #expect(state.roomTemperature == 20.5)
        #expect(state.outdoorTemperature == -4)
        #expect(state.fanSpeed == 0)
        #expect(state.actualFanSpeed == 3)
        #expect(state.vaneVertical == .auto)
        #expect(state.vaneHorizontal == .position3)
        #expect(state.wifiSignal == -67)
        #expect(state.errorCode == 8000)
        #expect(!state.hasActiveError)
        #expect(state.energy.currentConsumedKWh == 1234.5)
        #expect(state.energy.totalHeatingKWh == 1180.2)
        #expect(state.limits == TemperatureLimits(minHeat: 10, maxHeat: 31, minCoolDry: 16, maxCoolDry: 31, minAuto: 16, maxAuto: 31))
        #expect(state.lastCommunication != nil)  // falls back to LastTimeStamp
    }

    @Test func deviceGetOverridesListing() throws {
        let listing = MELCloudClassicParser.listedDevices(try Fixture.json("list_devices")).first
        let state = try MELCloudClassicParser.state(listing: listing, get: try Fixture.json("device_get"), fetchedAt: now)
        #expect(state.setTemperature == 21.5)
        #expect(state.roomTemperature == 20)
        #expect(state.fanSpeed == 2)
        #expect(state.vaneVertical == .swing)
        #expect(state.wifiSignal == -67)  // only in listing
        #expect(state.outdoorTemperature == -4)
        // LastCommunication is UTC on the wire.
        let expected = WireDate.parse("2026-11-05T09:58:12.345", timeZone: utc)
        #expect(state.lastCommunication == expected)
        #expect(state.nextCommunication != nil)
    }

    @Test func tolerantOfNullsAndBadTypes() throws {
        let state = try MELCloudClassicParser.state(listing: nil, get: try Fixture.json("device_get_nulls"), fetchedAt: now)
        #expect(state.roomTemperature == nil)
        #expect(state.setTemperature == 22.5)  // number sent as string
        #expect(state.mode == nil)  // unknown mode value
        #expect(state.power == false)
        #expect(state.offline)
        #expect(state.lastCommunication == nil)  // year-1 sentinel
        #expect(state.hasActiveError)
        #expect(state.errorCode == 5101)
    }

    @Test func missingDeviceIdFails() {
        #expect(throws: HeatPumpError.self) {
            try MELCloudClassicParser.state(listing: nil, get: .object([:]), fetchedAt: now)
        }
    }

    @Test func errorLog() throws {
        let entries = try MELCloudClassicParser.errorLog(try Fixture.json("error_log"), timeZone: utc)
        #expect(entries.count == 2)
        #expect(entries[0].message == "Kommunikasjonsfeil mellom innedel og utedel")
        #expect(entries[0].start == WireDate.parse("2026-10-20T03:12:00", timeZone: utc))
        #expect(entries[0].end == WireDate.parse("2026-10-20T03:16:00", timeZone: utc))
        #expect(entries[1].message == "Feil på romtemperaturføler")
        #expect(entries[1].end == nil)
    }

    @Test func errorLogFailure() throws {
        #expect(throws: HeatPumpError.server("FromDate: Ugyldig dato")) {
            try MELCloudClassicParser.errorLog(try Fixture.json("error_log_failure"), timeZone: utc)
        }
    }

    @Test func energyReportMapsBucketsToDays() throws {
        let start = WireDate.parse("2026-11-03", timeZone: utc)!
        let end = WireDate.parse("2026-11-05", timeZone: utc)!
        let days = MELCloudClassicParser.energy(try Fixture.json("energy_report"), range: DateInterval(start: start, end: end), timeZone: utc)
        #expect(days.map(\.day) == ["2026-11-03", "2026-11-04", "2026-11-05"])
        #expect(abs(days[0].totalKWh - 8.8) < 0.0001)
        #expect(days[0].heatingKWh == 8.5)
        #expect(days[1].totalKWh == 9.1)
        #expect(days[2].totalKWh == 0)
    }

    @Test func energyReportUsesDayLabelsWhenBucketCountDiffers() throws {
        let start = WireDate.parse("2026-11-01", timeZone: utc)!
        let end = WireDate.parse("2026-11-07", timeZone: utc)!
        let days = MELCloudClassicParser.energy(try Fixture.json("energy_report"), range: DateInterval(start: start, end: end), timeZone: utc)
        #expect(days.map(\.day) == ["2026-11-03", "2026-11-04", "2026-11-05"])
    }

    @Test func temperatureLog() throws {
        let points = MELCloudClassicParser.temperatureLog(try Fixture.json("temperature_log"), timeZone: utc)
        #expect(points.count == 3)
        #expect(points[0] == TemperaturePoint(timestamp: WireDate.parse("2026-11-04T10:00:00", timeZone: utc)!, room: 20.5, set: 21, outdoor: -3))
        #expect(points[2].room == nil)
        #expect(points[2].set == 21.5)
    }

    @Test func retryAfter() {
        #expect(MELCloudClassicParser.retryAfter("120", now: now) == now.addingTimeInterval(120))
        #expect(MELCloudClassicParser.retryAfter(nil, now: now) == now.addingTimeInterval(7200))
        #expect(MELCloudClassicParser.retryAfter("garbage", now: now) == now.addingTimeInterval(7200))
        let httpDate = MELCloudClassicParser.retryAfter("Thu, 05 Nov 2026 12:00:00 GMT", now: now)
        #expect(httpDate == WireDate.parse("2026-11-05T12:00:00Z", timeZone: utc))
    }

    @Test func wireDateFormats() {
        #expect(WireDate.parse("2026-11-05T10:00:00", timeZone: utc) == now)
        #expect(WireDate.parse("2026-11-05T10:00:00Z", timeZone: .current) == now)
        #expect(WireDate.parse("2026-11-05T11:00:00+01:00", timeZone: utc) == now)
        #expect(WireDate.parse("0001-01-01T00:00:00", timeZone: utc) == nil)
        #expect(WireDate.parse("", timeZone: utc) == nil)
        #expect(WireDate.day(now, timeZone: utc) == "2026-11-05")
        #expect(WireDate.localTimestamp(now, timeZone: utc) == "2026-11-05T10:00:00")
    }
}
