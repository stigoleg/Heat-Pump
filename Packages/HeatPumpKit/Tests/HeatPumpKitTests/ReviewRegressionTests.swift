import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit

/// Regression tests for the round-1 review findings (numbered as in the review).
@Suite("Review regressions")
struct ReviewRegressionTests {
    private func service(
        path: String = temporaryDatabasePath(), clock: TestClock, backend: CountingBackend,
        credentials: (any CredentialProviding)? = nil,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) throws -> HeatPumpService {
        HeatPumpService(
            backend: backend, store: try HistoryStore(path: path), credentials: credentials, timeZone: .gmt,
            now: clock.provider, sleep: sleep ?? clock.sleeper)
    }

    // 1. Setpoint validated against the pending mode, not the stale snapshot.
    @Test func setpointValidatedAgainstModeJustSent() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let path = temporaryDatabasePath()
        let svc = try service(path: path, clock: clock, backend: backend)
        _ = try await svc.currentState()
        #expect(try await svc.apply(.mode(.cool), source: .claude, reason: "kjøl").result == .ok)
        clock.advance(6)
        let low = try await svc.apply(.temperature(12), source: .claude, reason: "for kaldt i kjøling")
        #expect(low.result == .rejected)
        #expect(low.message.contains("Kjøling"))
        // Another process sharing the database sees the same expected state.
        let other = try service(path: path, clock: clock, backend: CountingBackend(now: clock.provider))
        #expect(try await other.apply(.temperature(12), source: .app, reason: "x").result == .rejected)
        #expect(await backend.applyCalls == 1)
    }

    @Test func batchValidatesSetpointAgainstModeInSameBatch() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try service(clock: clock, backend: backend)
        _ = try await svc.currentState()
        let rejected = try await svc.apply([.temperature(12), .mode(.cool)], source: .app, reason: "x")
        #expect(rejected.count == 2 && rejected.allSatisfy { $0.result == .rejected })
        #expect(await backend.applyCalls == 0)
        let ok = try await svc.apply([.temperature(20), .mode(.cool)], source: .app, reason: "x")
        #expect(ok.allSatisfy { $0.result == .ok })
    }

    @Test func freshSnapshotReplacesExpectedState() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try service(clock: clock, backend: backend)
        _ = try await svc.currentState()
        _ = try await svc.apply(.mode(.cool), source: .app, reason: "x")
        #expect(try await svc.effectiveState()?.mode == .cool)
        clock.advance(61)
        _ = try await svc.currentState()  // mock now reports cool too
        #expect(try await svc.effectiveState()?.fetchedAt == clock.now)
    }

    // 2. Refused credentials stop all network calls until new credentials are saved.
    @Test func invalidCredentialsStopNetworkUntilNewCredentials() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let creds = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "feil"))
        let svc = try service(clock: clock, backend: backend, credentials: creds)
        await backend.failNext(with: .invalidCredentials("Feil passord"))
        let first = try await svc.currentState()
        #expect(first.needsLogin)
        #expect(first.error?.contains("Innstillinger") == true)
        clock.advance(3600)
        let second = try await svc.currentState(force: true)
        #expect(second.needsLogin)
        #expect(await backend.fetchStateCalls == 1)
        let sync = try await svc.syncHistory()
        #expect(sync.allSatisfy { $0.status == .blocked })
        #expect(await backend.reportCalls == 0)

        try await svc.saveCredentials(MELCloudCredentials(email: "a@b.no", password: "riktig"))
        let third = try await svc.currentState(force: true)
        #expect(third.refreshed)
        #expect(!third.needsLogin)
    }

    @Test func persistentUnauthorizedBacksOffForAnHour() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try service(clock: clock, backend: backend)
        await backend.failNext(with: .unauthorized)
        let result = try await svc.currentState()
        #expect(result.blockedUntil == clock.now.addingTimeInterval(3600))
        clock.advance(120)
        _ = try await svc.currentState(force: true)
        #expect(await backend.fetchStateCalls == 1)
    }

    // 3. A 401 first retries with the ContextKey another process stored.
    @Test func unauthorizedRetriesWithKeyFromKeychainBeforeLogin() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        transport.enqueue("/User/ListDevices", status: 401, body: Data())
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        let creds = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "pw"), contextKey: "OLD")
        let backend = MELCloudClassicBackend(credentials: creds, transport: transport, timeZone: .gmt)
        _ = try await backend.listDevices()  // uses OLD
        try creds.saveContextKey("NEW")  // another process logged in meanwhile
        _ = try await backend.listDevices()
        let requests = transport.requests
        #expect(requests.map { $0.url?.lastPathComponent } == ["ListDevices", "ListDevices", "ListDevices"])
        #expect(requests[1].value(forHTTPHeaderField: "X-MitsContextKey") == "OLD")
        #expect(requests[2].value(forHTTPHeaderField: "X-MitsContextKey") == "NEW")
        #expect(creds.loadCount == 0)  // no login, so the password was never read
    }

    @Test func unauthorizedWithSameStoredKeyLogsInOnceAndKeepsKey() async throws {
        let transport = StubTransport()
        transport.enqueue("/User/ListDevices", status: 401, body: Data())
        transport.enqueue("/Login/ClientLogin", body: try Fixture.data("login_success"))
        transport.enqueue("/User/ListDevices", body: try Fixture.data("list_devices"))
        let creds = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "pw"), contextKey: "OLD")
        let backend = MELCloudClassicBackend(credentials: creds, transport: transport, timeZone: .gmt)
        _ = try await backend.listDevices()
        #expect(transport.requests.map { $0.url?.lastPathComponent } == ["ListDevices", "ClientLogin", "ListDevices"])
        #expect(creds.loadContextKey() == "FAKE-CONTEXT-KEY-0001")
    }

    // 4. Energy granularity.
    @Test func monthlyEnergyBucketsAreDropped() throws {
        var json = try Fixture.json("energy_report")
        guard case .object(var object) = json else { Issue.record("fixture"); return }
        object["LabelType"] = .number(2)
        json = .object(object)
        let start = WireDate.parse("2026-11-03", timeZone: .gmt)!
        let end = WireDate.parse("2026-11-05", timeZone: .gmt)!
        #expect(MELCloudClassicParser.energy(json, range: DateInterval(start: start, end: end), timeZone: .gmt).isEmpty)
    }

    @Test func ambiguousLongRangeEnergyIsDropped() throws {
        // 60-day range, 3 buckets labelled 3/4/5: could be months or days, so nothing is guessed.
        let start = WireDate.parse("2026-09-06", timeZone: .gmt)!
        let end = WireDate.parse("2026-11-05", timeZone: .gmt)!
        let days = MELCloudClassicParser.energy(
            try Fixture.json("energy_report"), range: DateInterval(start: start, end: end), timeZone: .gmt)
        #expect(days.isEmpty)
    }

    @Test func energySyncRequestsAtMost28Days() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try service(clock: clock, backend: backend)
        _ = try await svc.syncHistory()
        let range = try #require(await backend.energyRanges.first)
        #expect(range.duration <= 28 * 86_400)
    }

    // 5. Old data is reported as old, not as an offline unit.
    @Test func staleDataIsNotReportedAsOffline() {
        let now = Date(timeIntervalSince1970: 1_793_872_800)
        let fetched = now.addingTimeInterval(-3 * 3600)
        let state = makeState(at: fetched, lastCommunication: fetched.addingTimeInterval(-30))
        let report = HealthEngine.evaluate(
            HealthInput(latestState: state, now: now, timeZone: .gmt, blockedUntil: now.addingTimeInterval(3600)))
        let codes = report.findings.map(\.code)
        #expect(codes.contains("stale_data"))
        #expect(!codes.contains("offline"))
        let stale = report.findings.first { $0.code == "stale_data" }
        #expect(stale?.detail.contains("MELCloud har midlertidig stengt") == true)
        #expect(stale?.recommendation.contains("sikringen") == false)
    }

    @Test func offlineJudgedAgainstFetchTime() {
        let now = Date(timeIntervalSince1970: 1_793_872_800)
        let silent = makeState(at: now, lastCommunication: now.addingTimeInterval(-2 * 3600))
        #expect(HealthEngine.evaluate(HealthInput(latestState: silent, now: now)).findings.contains { $0.code == "offline" })
    }

    // 6. Date parsing is total.
    @Test func dateParsingNeverTraps() {
        let garbage = [
            "2026-11-05T.", "T", "T.", "-", "--", "2026-11-05T", "2026-11-05T10", "2026-11-05T10:00.",
            "2026-11-05T10:00:00.", "2026-13-01", "2026-00-10", "2026-11-05T25:00", "99999999999999999999-01-01",
            "2026-11-05T10:00:00.abc", "2026-11-05T10:00:00+01:00x", "Z", "+01:00", String(repeating: "9", count: 500),
        ]
        for text in garbage {
            _ = WireDate.parse(text, timeZone: .gmt)
        }
        #expect(WireDate.parse("2026-11-05T.", timeZone: .gmt) == nil)
        #expect(WireDate.parse("2026-11-05T10:00", timeZone: .gmt) != nil)
        #expect(JSONValue.number(1e300).int == nil)
        #expect(JSONValue.number(.nan).int == nil)
        #expect(JSONValue.number(1e300).string != nil)
    }

    // 7. Invalid limits fall back to defaults.
    @Test func nonsenseLimitsFallBack() {
        let limits = TemperatureLimits(minHeat: 10, maxHeat: 31, minCoolDry: 16, maxCoolDry: 31, minAuto: 16, maxAuto: 0)
        #expect(limits.range(for: .auto) == 16...31)
        #expect(TemperatureLimits(minHeat: .nan, maxHeat: 31).range(for: .heat) == 10...31)
        #expect(limits.range(for: .heat) == 10...31)
    }

    // 8. HasError without a real code is a warning with sensible wording.
    @Test func errorFlagWithoutCode() {
        let now = Date(timeIntervalSince1970: 1_793_872_800)
        for code: Int? in [8000, 0, nil] {
            let report = HealthEngine.evaluate(
                HealthInput(latestState: makeState(at: now, hasError: true, errorCode: code), now: now))
            let finding = report.findings.first { $0.code == "error_flag" }
            #expect(finding?.severity == .warning)
            #expect(finding?.title.contains("uten feilkode") == true)
            #expect(!report.findings.contains { $0.code == "active_error" })
            #expect(!report.findings.contains { $0.detail.contains("Ingen feil") })
        }
    }

    // 9. Writes are spaced across processes and batches go out as one request.
    @Test func writesAreSpacedAcrossProcesses() async throws {
        let path = temporaryDatabasePath()
        let clock = TestClock()
        let waits = Mutex<[TimeInterval]>([])
        let sleeper: @Sendable (TimeInterval) async -> Void = { seconds in
            waits.withLock { $0.append(seconds) }
            clock.advance(seconds)
        }
        let a = try service(path: path, clock: clock, backend: CountingBackend(now: clock.provider), sleep: sleeper)
        let backendB = CountingBackend(now: clock.provider)
        let b = try service(path: path, clock: clock, backend: backendB, sleep: sleeper)
        _ = try await a.currentState()
        #expect(try await a.apply(.fanSpeed(2), source: .app, reason: "x").result == .ok)
        clock.advance(1)
        #expect(try await b.apply(.fanSpeed(3), source: .claude, reason: "y").result == .ok)
        let waited = waits.withLock { $0 }
        #expect(waited.count == 1)
        #expect((waited.first ?? 0) >= 3.9 && (waited.first ?? 0) <= 4.1)
        #expect(await backendB.applyCalls == 1)
    }

    @Test func writeRejectedWhenSpacingCannotBeMet() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        // A sleeper that does not advance time: the spacing never clears.
        let svc = try service(clock: clock, backend: backend, sleep: { _ in })
        _ = try await svc.currentState()
        #expect(try await svc.apply(.fanSpeed(2), source: .app, reason: "x").result == .ok)
        let second = try await svc.apply(.fanSpeed(3), source: .app, reason: "y")
        #expect(second.result == .rejected)
        #expect(second.nextAllowed != nil)
        #expect(await backend.applyCalls == 1)
    }

    @Test func batchGoesOutAsOneRequestAndVanesSeparately() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let store = try HistoryStore(path: temporaryDatabasePath())
        let svc = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await svc.currentState()
        let outcomes = try await svc.apply(
            [.power(true), .mode(.heat), .temperature(22), .fanSpeed(3), .vaneVertical(.position5), .vaneHorizontal(.swing)],
            source: .app, reason: "kontroll")
        #expect(outcomes.count == 6 && outcomes.allSatisfy { $0.result == .ok })
        let sets = await backend.appliedChanges()
        #expect(sets.count == 2)
        let first = try #require(sets.first)
        #expect(first.power == true && first.mode == .heat && first.setTemperature == 22 && first.fanSpeed == 3)
        #expect(first.vaneVertical == .position5 && first.vaneHorizontal == nil)
        #expect(sets.last?.vaneHorizontal == .swing && sets.last?.setTemperature == nil)
        let flags = try MELCloudClassicParser.setAtaPayload(first, raw: try Fixture.json("device_get_full"))["EffectiveFlags"]
        #expect(flags == .number(Double(0x01 | 0x02 | 0x04 | 0x08 | 0x10)))
        // The budget counts requests, not fields.
        let batches = Set(try store.changes(limit: 10).map(\.timestamp))
        #expect(batches.count == 2)
    }

    // 10. Maintenance dates and reason; knowledge text corrections.
    @Test func maintenanceRejectsFutureAndKeepsReason() async throws {
        let clock = TestClock()
        let svc = try service(clock: clock, backend: CountingBackend(now: clock.provider))
        await #expect(throws: HeatPumpError.self) {
            try await svc.recordMaintenance(kind: .airFilter, date: clock.now.addingTimeInterval(86_400))
        }
        let record = try await svc.recordMaintenance(kind: .airFilter, note: "Støvsuget", reason: "Brukeren sa det i chatten")
        #expect(record.note == "Støvsuget\nBegrunnelse: Brukeren sa det i chatten")
    }

    @Test func knowledgeCorrections() throws {
        let codes = try #require(Knowledge.document(named: "error-codes")).markdown
        #expect(!codes.contains("Tabellen for utedelen (§10-2.5)"))
        #expect(codes.contains("§10-2.5"))
        #expect(codes.contains("luftrens"))
        let profile = try #require(Knowledge.document(named: "unit-profile")).markdown
        #expect(!profile.contains("merkeområdet"))
        #expect(profile.contains("garantert"))
    }
}
