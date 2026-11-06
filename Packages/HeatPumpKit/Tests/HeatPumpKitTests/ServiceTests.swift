import Foundation
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration
@testable import MELCloudIntegration

@Suite("Setpoint validation")
struct ValidationTests {
    let state = makeState(at: Date(), mode: .heat)

    private func validated(_ change: DeviceChange, _ state: DeviceState) -> DeviceChange? {
        if case .success(let value) = HeatPumpService.validate(change, against: state) { return value }
        return nil
    }

    @Test func roundsToHalfDegree() {
        #expect(validated(.temperature(21.3), state) == .temperature(21.5))
        #expect(validated(.temperature(21.2), state) == .temperature(21.0))
        #expect(validated(.temperature(21.75), state) == .temperature(22.0))
    }

    @Test func rejectsOutsideModeLimits() {
        #expect(validated(.temperature(9.5), state) == nil)
        #expect(validated(.temperature(31.5), state) == nil)
        #expect(validated(.temperature(10), state) == .temperature(10))
        #expect(validated(.temperature(31), state) == .temperature(31))
        var cooling = state
        cooling.mode = .cool
        #expect(validated(.temperature(14), cooling) == nil)  // cool/dry min is 16
        #expect(validated(.temperature(16), cooling) == .temperature(16))
        #expect(validated(.temperature(.nan), state) == nil)
    }

    @Test func fanSpeedRange() {
        #expect(validated(.fanSpeed(0), state) == .fanSpeed(0))
        #expect(validated(.fanSpeed(5), state) == .fanSpeed(5))
        #expect(validated(.fanSpeed(6), state) == nil)
        #expect(validated(.fanSpeed(-1), state) == nil)
    }
}

@Suite("Cross-process coordination")
struct CoordinationTests {
    @Test func fetchReservationIsSharedBetweenPools() throws {
        let path = temporaryDatabasePath()
        let processA = try HistoryStore(path: path)
        let processB = try HistoryStore(path: path)  // separate DatabasePool on the same file
        let t = Date(timeIntervalSince1970: 1_793_872_800)
        #expect(try processA.reserveFetch(key: "state", minInterval: 60, now: t) == .allowed)
        #expect(try processB.reserveFetch(key: "state", minInterval: 60, now: t.addingTimeInterval(30))
            == .throttled(nextAllowed: t.addingTimeInterval(60)))
        #expect(try processB.reserveFetch(key: "state", minInterval: 60, now: t.addingTimeInterval(61)) == .allowed)
        #expect(try processA.reserveFetch(key: "state", minInterval: 60, now: t.addingTimeInterval(62))
            == .throttled(nextAllowed: t.addingTimeInterval(121)))
    }

    @Test func concurrentReservationsAllowExactlyOne() async throws {
        let path = temporaryDatabasePath()
        let stores = try (0..<4).map { _ in try HistoryStore(path: path) }
        let t = Date(timeIntervalSince1970: 1_793_872_800)
        let decisions = try await withThrowingTaskGroup(of: FetchDecision.self) { group in
            for i in 0..<20 {
                let store = stores[i % stores.count]
                group.addTask { try store.reserveFetch(key: "state", minInterval: 60, now: t) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(decisions.filter { $0 == .allowed }.count == 1)
    }

    @Test func blockIsSeenByOtherPoolAndKeepsLatest() throws {
        let path = temporaryDatabasePath()
        let processA = try HistoryStore(path: path)
        let processB = try HistoryStore(path: path)
        let t = Date(timeIntervalSince1970: 1_793_872_800)
        try processA.recordBlock(until: t.addingTimeInterval(7200), reason: .loginThrottled)
        try processB.recordBlock(until: t.addingTimeInterval(600), reason: .rateLimited)  // shorter block must not shorten it
        #expect(try processB.reserveFetch(key: "report.energy", minInterval: 3600, now: t)
            == .blocked(until: t.addingTimeInterval(7200)))
        #expect(try processB.blockedUntil(now: t) == t.addingTimeInterval(7200))
        #expect(try processB.blockStatus(now: t) == BlockStatus(until: t.addingTimeInterval(7200), reason: .loginThrottled))
        #expect(try processA.blockedUntil(now: t.addingTimeInterval(7201)) == nil)
    }

    @Test func forcedRefreshAtMostOncePerMinuteAcrossServices() async throws {
        let path = temporaryDatabasePath()
        let clock = TestClock()
        let backendA = CountingBackend(now: clock.provider)
        let backendB = CountingBackend(now: clock.provider)
        let serviceA = HeatPumpService(backend: backendA, store: try HistoryStore(path: path), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let serviceB = HeatPumpService(backend: backendB, store: try HistoryStore(path: path), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)

        let first = try await serviceA.currentState(force: true)
        #expect(first.refreshed)
        clock.advance(20)
        let second = try await serviceB.currentState(force: true)
        #expect(!second.refreshed)
        #expect(second.state != nil)  // served from the shared cache written by A
        #expect(second.nextRefreshAllowed == first.fetchedAt!.addingTimeInterval(60))
        clock.advance(41)
        let third = try await serviceB.currentState(force: true)
        #expect(third.refreshed)
        #expect(await backendA.fetchStateCalls == 1)
        #expect(await backendB.fetchStateCalls == 1)
    }

    @Test func cacheServedWithinMaxAge() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let service = HeatPumpService(backend: backend, store: try HistoryStore(path: temporaryDatabasePath()), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        clock.advance(300)
        let cached = try await service.currentState()
        #expect(!cached.refreshed)
        #expect(cached.dataAgeSeconds == 300)
        clock.advance(301)
        #expect(try await service.currentState().refreshed)
        #expect(await backend.fetchStateCalls == 2)
    }

    @Test func rateLimitBlocksAllProcesses() async throws {
        let path = temporaryDatabasePath()
        let clock = TestClock()
        let backendA = CountingBackend(now: clock.provider)
        let backendB = CountingBackend(now: clock.provider)
        let serviceA = HeatPumpService(backend: backendA, store: try HistoryStore(path: path), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let serviceB = HeatPumpService(backend: backendB, store: try HistoryStore(path: path), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await serviceA.currentState()

        clock.advance(700)
        let until = clock.now.addingTimeInterval(7200)
        await backendA.failNext(with: .rateLimited(until: until))
        let limited = try await serviceA.currentState()
        #expect(limited.blockedUntil == until)
        #expect(limited.state != nil)
        #expect(limited.stale)

        clock.advance(3600)
        let fromB = try await serviceB.currentState(force: true)
        #expect(!fromB.refreshed)
        #expect(fromB.blockedUntil == until)
        #expect(await backendB.fetchStateCalls == 0)
        let sync = try await serviceB.syncHistory()
        #expect(sync.allSatisfy { $0.status == .blocked })
        #expect(await backendB.reportCalls == 0)
        let change = try await serviceB.apply(.temperature(22), source: .app, reason: "test")
        #expect(change.result == .rejected)
        #expect(change.blockedUntil == until)
        #expect(await backendB.applyCalls == 0)

        clock.advance(3601)
        #expect(try await serviceB.currentState().refreshed)
    }

    @Test func historySyncAtMostHourly() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let service = HeatPumpService(backend: backend, store: try HistoryStore(path: temporaryDatabasePath()), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let first = try await service.syncHistory()
        #expect(first.allSatisfy { $0.status == .fetched })
        #expect(await backend.reportCalls == 3)
        clock.advance(1800)
        let second = try await service.syncHistory()
        #expect(second.allSatisfy { $0.status == .skipped })
        #expect(await backend.reportCalls == 3)
        clock.advance(1801)
        _ = try await service.syncHistory()
        #expect(await backend.reportCalls == 6)
        #expect(try await service.errorLog(days: 90).isEmpty == false)
    }
}

@Suite("Changes")
struct ChangeTests {
    @Test func appliedChangeIsLoggedAndMarksCacheStale() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        let outcome = try await service.apply(.temperature(21.3), source: .claude, reason: "Litt kaldt")
        #expect(outcome.result == .ok)
        #expect(outcome.newValue == "21.5")
        #expect(outcome.oldValue == "21.0")
        let log = try store.changes(limit: 10)
        #expect(log.count == 1)
        #expect(log[0].source == .claude)
        #expect(log[0].result == .ok)
        #expect(log[0].reason == "Litt kaldt")
        #expect(try store.latestSnapshot()?.stale == true)
        clock.advance(61)
        let refreshed = try await service.currentState()
        #expect(refreshed.refreshed)
        #expect(refreshed.state?.setTemperature == 21.5)
    }

    @Test func rejectedChangeIsLoggedAndNotSent() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        let outcome = try await service.apply(.temperature(35), source: .app, reason: "for varmt")
        #expect(outcome.result == .rejected)
        #expect(await backend.applyCalls == 0)
        #expect(try store.changes(limit: 1).first?.result == .rejected)
    }

    @Test func failedSendIsLogged() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let store = try HistoryStore(path: temporaryDatabasePath())
        let service = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await service.currentState()
        await backend.failNext(with: .http(status: 500))
        let outcome = try await service.apply(.power(false), source: .app, reason: "test")
        #expect(outcome.result == .failed)
        let row = try #require(try store.changes(limit: 1).first)
        #expect(row.result == .failed)
        #expect(row.error?.contains("500") == true)
    }

    @Test func changeBudgetIsSharedAcrossProcesses() async throws {
        let path = temporaryDatabasePath()
        let clock = TestClock()
        let backendA = CountingBackend(now: clock.provider)
        let backendB = CountingBackend(now: clock.provider)
        let serviceA = HeatPumpService(backend: backendA, store: try HistoryStore(path: path), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        let serviceB = HeatPumpService(backend: backendB, store: try HistoryStore(path: path), timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await serviceA.currentState()
        for i in 0..<12 {
            let service = i.isMultiple(of: 2) ? serviceA : serviceB
            let outcome = try await service.apply(.fanSpeed(i % 5), source: i.isMultiple(of: 2) ? .app : .claude, reason: "budsjett \(i)")
            #expect(outcome.result == .ok)
            clock.advance(60)
        }
        let start = clock.now.addingTimeInterval(-12 * 60)
        let over = try await serviceB.apply(.fanSpeed(1), source: .claude, reason: "nr 13")
        #expect(over.result == .rejected)
        #expect(over.nextAllowed == start.addingTimeInterval(3600))
        #expect(await backendA.applyCalls + backendB.applyCalls == 12)

        clock.advance(over.nextAllowed!.timeIntervalSince(clock.now) + 1)
        #expect(try await serviceA.apply(.fanSpeed(2), source: .app, reason: "etter vinduet").result == .ok)
    }

    @Test func rejectedChangesDoNotUseBudget() throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let t = Date(timeIntervalSince1970: 1_793_872_800)
        for _ in 0..<20 {
            try store.logChange(ChangeRecord(timestamp: t, source: .claude, field: "power", oldValue: "on", newValue: "off", reason: "x", result: .rejected))
        }
        let reservation = try store.reserveChange([
            ChangeRecord(timestamp: t, source: .app, field: "power", oldValue: "on", newValue: "off", reason: "y", result: .pending)
        ])
        guard case .reserved = reservation else { Issue.record("expected reservation, got \(reservation)"); return }
    }

    @Test func maintenanceStatus() async throws {
        let clock = TestClock()
        let service = HeatPumpService(
            backend: CountingBackend(now: clock.provider), store: try HistoryStore(path: temporaryDatabasePath()),
            timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        try await service.recordMaintenance(kind: .airFilter, date: clock.now.addingTimeInterval(-20 * 86_400), note: "støvsuget")
        let status = try await service.maintenanceStatus()
        let air = try #require(status.first { $0.kind == .airFilter })
        #expect(air.status == "due")
        #expect(air.daysSince == 20)
        #expect(air.note == "støvsuget")
        #expect(status.first { $0.kind == .deodorizingFilter }?.status == "unknown")
        #expect(status.first { $0.kind == .professionalService }?.status == "not_applicable")
    }
}

@Suite("Knowledge resources")
struct KnowledgeTests {
    @Test func allDocumentsLoad() {
        let docs = Knowledge.all()
        #expect(docs.map(\.name) == Knowledge.names)
        #expect(docs.allSatisfy { !$0.markdown.isEmpty && !$0.title.isEmpty })
        #expect(docs.first?.uri == "varmepumpe://knowledge/unit-profile")
    }

    @Test func errorCatalogStatesConfidence() {
        #expect(ErrorCatalog.lookup(errorCode: 8000).confidence == .medium)
        #expect(ErrorCatalog.lookup(errorCode: 5101).confidence == .low)
        let unknown = ErrorCatalog.lookup(errorCode: 4242)
        #expect(unknown.confidence == .unknown)
        #expect(unknown.explanation.contains("no reliable explanation"))
        let fromMessage = ErrorCatalog.lookup(errorCode: nil, message: "Feil på føler")
        #expect(fromMessage.confidence == .serviceText)
        #expect(ErrorCatalog.blinkCodes[2]?.source.contains("MSZ-LN") == true)
    }
}

@Suite("Compiled knowledge")
struct CompiledKnowledgeTests {
    /// The compiled documents of every target with a `Knowledge` folder. A new target with
    /// documents must be added here.
    static let compiled: [String: KnowledgeSource] = ["MELCloudIntegration": MELCloudIntegration().knowledge]

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    @Test func everyKnowledgeFolderIsCompiled() throws {
        let targets = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "Knowledge").path) }
            .map(\.lastPathComponent)
        #expect(Set(targets) == Set(Self.compiled.keys))
    }

    /// Fails when Knowledge/<lang>/*.md changed without running scripts/generate-knowledge.py.
    @Test(arguments: L10n.Language.allCases)
    func compiledContentMatchesMarkdownFiles(language: L10n.Language) throws {
        for (target, source) in Self.compiled {
            let directory = Self.sources.appending(path: "\(target)/Knowledge/\(language.rawValue)")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
            #expect(Set(files.map { $0.deletingPathExtension().lastPathComponent }) == Set(source.names), "\(target)")
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                let onDisk = try String(contentsOf: file, encoding: .utf8)
                let compiled = try #require(source.documents[language.rawValue]?[name], "\(target)/\(language.rawValue)/\(name)")
                #expect(compiled == onDisk.trimmingCharacters(in: .newlines), "\(target)/\(language.rawValue)/\(name) is out of date")
            }
        }
    }
}
