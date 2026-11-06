import Foundation
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration
@testable import MELCloudIntegration

@Suite("Firmware updates of the Wi-Fi adapter")
struct FirmwareTests {
    let clock = TestClock()

    // MARK: Phase mapping (MELCloud web client getFirmwareStatus, first match wins)

    @Test(arguments: [
        // phase 0, approval 0|1: approval required, or unit offline when more than 5 minutes offline
        (0, 0, 0, FirmwareUpdatePhase.approvalRequired), (0, 1, 0, .approvalRequired), (0, 1, 5, .approvalRequired),
        (0, 0, 6, .unitOffline), (0, 1, 30, .unitOffline),
        // phase 1
        (1, 3, 0, .approved), (1, 6, 0, .approved), (1, 4, 0, .cancelling),
        // reset
        (6, 3, 0, .resetPending), (6, 6, 0, .resetPending), (7, 3, 0, .resetting), (7, 6, 0, .resetting),
        // download
        (2, 3, 0, .downloading), (2, 6, 0, .downloading), (3, 3, 0, .retrying), (3, 6, 0, .retrying),
        // complete wins over blocked (approval 5) and forced (approval 6)
        (4, 0, 0, .complete), (4, 5, 0, .complete), (4, 6, 0, .complete),
        // blocked: approval 5 in any phase but 5
        (0, 5, 0, .blocked), (2, 5, 0, .blocked), (8, 5, 0, .blocked),
        // aborted: phase 5 with approval <= 4 or 6; offline when at least 5 minutes offline
        (5, 0, 0, .aborted), (5, 4, 4, .aborted), (5, 6, 0, .aborted), (5, 3, 5, .abortedOffline), (5, 6, 10, .abortedOffline),
        // forced: approval 6 outside phases 4 and 5 that no earlier rule took
        (0, 6, 0, .forced), (8, 6, 0, .forced),
        // nothing matched
        (5, 5, 0, .unknown), (0, 2, 0, .unknown), (1, 0, 0, .unknown), (2, 0, 0, .unknown), (9, 3, 0, .unknown), (4, 7, 0, .unknown),
    ])
    func phaseMapping(_ phase: Int, _ approval: Int, _ minutes: Int, _ expected: FirmwareUpdatePhase) {
        #expect(FirmwareUpdatePhase.from(phase: phase, approval: approval, minutesOffline: minutes) == expected)
    }

    @Test func missingNumbersAndActions() {
        #expect(FirmwareUpdatePhase.from(phase: nil, approval: 0, minutesOffline: 0) == .unknown)
        #expect(FirmwareUpdatePhase.from(phase: 0, approval: nil, minutesOffline: 0) == .unknown)
        #expect(FirmwareUpdatePhase.from(phase: 0, approval: 0, minutesOffline: nil) == .approvalRequired)
        #expect(Set(FirmwareUpdatePhase.allCases.filter(\.canApprove)) == [.approvalRequired, .aborted, .abortedOffline])
        #expect(Set(FirmwareUpdatePhase.allCases.filter(\.canCancel)) == [.approved, .downloading, .retrying, .forced])
        for phase in FirmwareUpdatePhase.allCases { #expect(!phase.displayText.isEmpty) }
        let unknown = FirmwareUpdateStatus(currentPhase: 9, approvalStatus: 3)
        #expect(unknown.phase == .unknown)
        #expect(unknown.displayText.contains("phase 9, approval 3"))
        let downloading = FirmwareUpdateStatus(currentPhase: 2, approvalStatus: 3, filesDownloaded: 2, filesToDownload: 4)
        #expect(downloading.displayText.contains("2 of 4 files"))
        #expect(downloading.progress == 0.5)
    }

    @Test func listIsParsedTolerantly() throws {
        let json = try JSONValue.parse(Data("""
            [{"ID": 77, "Device": 1, "CurrentPhase": 2, "CurrentApprovalStatus": 3, "MinutesOffline": 0, "FilesDownloaded": 1,
              "FilesToDownload": 3, "Retries": 0, "DateApproved": "2026-11-05T11:00:00", "DateCreated": "2026-11-01T08:00:00",
              "LastCommunication": null},
             {"ID": 78}, 5, null]
            """.utf8))
        let updates = MELCloudClassicParser.firmwareUpdates(json, timeZone: .gmt)
        #expect(updates.count == 2)
        #expect(updates[0].id == 77)
        #expect(updates[0].device == .melcloud(1))
        #expect(updates[0].phase == .downloading)
        #expect(updates[0].progressText == "1 of 3 files")
        #expect(updates[0].dateApproved == Date(timeIntervalSince1970: 1_793_876_400))
        #expect(updates[0].lastCommunication == nil)
        #expect(updates[1] == FirmwareUpdateStatus(id: 78))
        #expect(updates[1].phase == .unknown)
        #expect(MELCloudClassicParser.firmwareUpdates(.null, timeZone: .gmt).isEmpty)
        // The newest entry is the one that counts.
        let status = FirmwareStatus(updates: [
            FirmwareUpdateStatus(id: 1, currentPhase: 4, approvalStatus: 3, dateCreated: Date(timeIntervalSince1970: 1)),
            FirmwareUpdateStatus(id: 2, currentPhase: 0, approvalStatus: 0, dateCreated: Date(timeIntervalSince1970: 2)),
        ])
        #expect(status.current?.id == 2)
    }

    @Test func accessLevelComesFromTheListing() throws {
        let listing: JSONValue = .object([
            "DeviceID": .number(1), "AccessLevel": .number(4),
            "Device": .object(["DeviceID": .number(1), "FirmwareDeployment": .string("123"), "FirmwareAppVersion": .number(34000)]),
        ])
        let firmware = try MELCloudClassicParser.state(listing: listing, get: nil, fetchedAt: clock.now).firmware
        #expect(firmware.accessLevel == 4)
        #expect(firmware.isOwner == true)
        #expect(FirmwareInfo(accessLevel: 2).isOwner == false)
        #expect(FirmwareInfo().isOwner == nil)
    }

    // MARK: Requests (MELCloud Classic)

    func classic(_ transport: StubTransport) -> MELCloudClassicBackend {
        let credentials = InMemoryCredentialStore(
            credentials: MELCloudCredentials(email: "user@example.com", password: "secret"), contextKey: "KEY")
        return MELCloudClassicBackend(credentials: credentials, transport: transport, timeZone: .gmt, now: clock.provider)
    }

    func body(_ request: URLRequest?) throws -> JSONValue {
        try JSONValue.parse(try #require(request?.httpBody))
    }

    @Test func requestPathsAndBodies() async throws {
        let transport = StubTransport()
        transport.enqueue("/FirmwareUpdate/List2", body: Data(#"[{"ID": 77, "Device": 12345, "CurrentPhase": 0, "CurrentApprovalStatus": 0}]"#.utf8))
        transport.enqueue("/FirmwareUpdate/Approve2", body: Data("{}".utf8))
        transport.enqueue("/FirmwareUpdate/Cancel2", body: Data())
        let backend = classic(transport)
        let updates = try await backend.firmwareUpdates(device: .melcloud(12345))
        #expect(updates.map(\.id) == [77])
        try await backend.approveFirmwareUpdate(id: 77, device: .melcloud(12345))
        try await backend.cancelFirmwareUpdate(id: 77, device: .melcloud(12345))
        let requests = transport.requests
        #expect(requests.map { $0.url?.path ?? "" } == [
            "/Mitsubishi.Wifi.Client/FirmwareUpdate/List2", "/Mitsubishi.Wifi.Client/FirmwareUpdate/Approve2",
            "/Mitsubishi.Wifi.Client/FirmwareUpdate/Cancel2",
        ])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "X-MitsContextKey") == "KEY" })
        #expect(try body(requests[0]) == .array([.number(12345)]))
        #expect(try body(requests[1]) == .object(["id": .number(77), "deviceid": .number(12345)]))
        #expect(try body(requests[2]) == .object(["id": .number(77), "deviceid": .number(12345)]))
    }

    @Test func refusedActionNeverLogsIn() async throws {
        let transport = StubTransport()
        transport.enqueue("/FirmwareUpdate/Approve2", status: 403, body: Data())
        transport.enqueue("/FirmwareUpdate/Cancel2", body: Data(#"{"Success": false}"#.utf8))
        let backend = classic(transport)
        await #expect(throws: HeatPumpError.endpointRefused(status: 403)) { try await backend.approveFirmwareUpdate(id: 1, device: .melcloud(2)) }
        await #expect(throws: HeatPumpError.self) { try await backend.cancelFirmwareUpdate(id: 1, device: .melcloud(2)) }
        #expect(!transport.requests.contains { $0.url?.path.hasSuffix("ClientLogin") == true })
    }

    // MARK: Service refusals

    func waitingState(owner: Int? = 4, offline: Bool = false, deployment: String? = "4711") -> DeviceState {
        var state = makeState(at: clock.now, offline: offline, firmware: FirmwareInfo(
            deployment: deployment, appVersion: 34000, accessLevel: owner))
        state.key = MockBackend.device
        return state
    }

    func service(_ backend: any HeatPumpBackend, store: HistoryStore) -> HeatPumpService {
        HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
    }

    @Test(arguments: [
        (4 as Int?, true, "4711" as String?, "disconnected"),
        (2, false, "4711", "Only the owner"),
        (nil, false, "4711", "not said whether the account owns"),
        (4, false, nil, "No firmware update is waiting"),
    ])
    func refusalsAreLoggedAndSendNothing(_ owner: Int?, _ offline: Bool, _ deployment: String?, _ text: String) async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        try store.insertSnapshot(waitingState(owner: owner, offline: offline, deployment: deployment))
        let approver = RecordingApprover(.approved)
        let outcome = try await service(backend, store: store).startFirmwareUpdate(source: .claude, reason: "Oppdater", approver: approver)
        #expect(outcome.result == .rejected)
        #expect(outcome.message.contains(text))
        #expect(approver.received.isEmpty)
        #expect(await backend.firmwareReads == 0)
        #expect(await backend.firmwareApprovals == 0)
        let row = try #require(try store.changes(limit: 1).first)
        #expect(row.field == "firmware")
        #expect(row.result == .rejected)
        #expect(row.source == .claude)
        #expect(row.oldValue == "34.00")
        #expect(try await service(backend, store: store).writeBudget().remaining == ChangeBudget.maxChangesPerHour)
    }

    @Test func listSayingOfflineOrNotApprovableSendsNothing() async throws {
        for (entry, text) in [
            (#"[{"ID": 77, "Device": 1, "CurrentPhase": 0, "CurrentApprovalStatus": 0, "MinutesOffline": 12}]"#, "disconnected"),
            (#"[{"ID": 77, "Device": 1, "CurrentPhase": 2, "CurrentApprovalStatus": 3, "MinutesOffline": 0}]"#, "cannot be started now"),
            ("[]", "update list"),
        ] {
            let transport = StubTransport()
            transport.enqueue("/FirmwareUpdate/List2", body: Data(entry.utf8))
            let store = try HistoryStore(path: temporaryDatabasePath())
            var state = waitingState()
            state.key = testDevice
            try store.insertSnapshot(state)
            let outcome = try await service(classic(transport), store: store).startFirmwareUpdate(source: .app, reason: "x")
            #expect(outcome.result == .rejected)
            #expect(outcome.message.contains(text))
            let approvals = transport.requests.filter { $0.url?.path.hasSuffix("Approve2") == true }
            #expect(approvals.count == 0)
            #expect(try store.changes(limit: 1).first?.result == .rejected)
        }
    }

    @Test func claudeRejectedInTheDialogSendsNothing() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let svc = service(backend, store: store)
        _ = try await svc.currentState()
        let approver = RecordingApprover(.rejected)
        let outcome = try await svc.startFirmwareUpdate(source: .claude, reason: "Sikkerhetsoppdatering", approver: approver)
        #expect(outcome.result == .rejected)
        #expect(await backend.firmwareApprovals == 0)
        let request = try #require(approver.received.first)
        let text = request.summaries.joined(separator: " ")
        #expect(request.summaries.first == "Start a firmware update of the Wi-Fi adapter (now version 34.00)")
        #expect(text.contains("cannot be rolled back"))
        #expect(text.contains("power") && text.contains("good Wi-Fi"))
        #expect(text.contains("remote control"))
        #expect(text.contains("restarts") && text.contains("take a while"))
        #expect(request.reason == "Sikkerhetsoppdatering")
        let row = try #require(try store.changes(limit: 1).first)
        #expect(row.result == .rejected)
        #expect(row.error == ApprovalDecision.rejected.rejectionText)
        // A timeout counts as a refusal too.
        let timedOut = try await svc.startFirmwareUpdate(source: .claude, reason: "x", approver: RecordingApprover(.timedOut))
        #expect(timedOut.result == .rejected)
        #expect(await backend.firmwareApprovals == 0)
    }

    /// Approver that, while "the dialog is open", lets something happen and then approves.
    final class ApproveAfter: ChangeApprover, @unchecked Sendable {
        let during: () throws -> Void
        init(_ during: @escaping () throws -> Void) { self.during = during }
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            try? during()
            return .approved
        }
    }

    @Test func blockArrivingWhileTheDialogIsOpenStopsTheStart() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let svc = service(backend, store: store)
        _ = try await svc.currentState()
        let approver = ApproveAfter { try store.recordBlock(until: self.clock.now.addingTimeInterval(3600), reason: .rateLimited) }
        let outcome = try await svc.startFirmwareUpdate(source: .claude, reason: "x", approver: approver)
        #expect(outcome.result == .rejected)
        #expect(outcome.blockedUntil != nil)
        #expect(await backend.firmwareApprovals == 0)
    }

    @Test func claudeCannotLiftARefusalPause() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let svc = service(backend, store: store)
        _ = try await svc.currentState()
        try store.recordKeyRefusal(key: HistoryStore.fetchKey(HeatPumpService.firmwareFetchKey, integration: testIntegration.id), until: clock.now.addingTimeInterval(86_400))
        let outcome = try await svc.startFirmwareUpdate(source: .claude, reason: "x", approver: RecordingApprover(.approved))
        #expect(outcome.result == .rejected)
        #expect(await backend.firmwareReads == 0)
        #expect(await backend.firmwareApprovals == 0)
    }

    @Test func blockedOrCredentialsRejectedSendsNothing() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let svc = service(backend, store: store)
        _ = try await svc.currentState()
        try store.recordBlock(until: clock.now.addingTimeInterval(3600), reason: .rateLimited)
        let blocked = try await svc.startFirmwareUpdate(source: .app, reason: "x")
        #expect(blocked.result == .rejected)
        #expect(blocked.blockedUntil != nil)
        #expect(await backend.firmwareReads == 0)
        let status = try await svc.firmwareStatus(force: true)
        #expect(status.message != nil)
        #expect(await backend.firmwareReads == 0)
    }

    // MARK: Simulated flow

    @Test func mockUpdateRunsToCompletion() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let svc = service(backend, store: store)
        _ = try await svc.currentState()
        let waiting = try await svc.firmwareStatus()
        #expect(waiting.phase == .approvalRequired)
        #expect(waiting.canStart)
        #expect(waiting.currentVersion == "34.00")
        #expect(await backend.firmwareReads == 1)
        // Cached for 60 s while nothing runs.
        clock.advance(30)
        _ = try await svc.firmwareStatus()
        #expect(await backend.firmwareReads == 1)

        let outcome = try await svc.startFirmwareUpdate(source: .app, reason: "Startet i appen")
        #expect(outcome.result == .ok)
        #expect(await backend.firmwareApprovals == 1)
        let row = try #require(try store.changes(limit: 1).first)
        #expect(row.field == "firmware")
        #expect(row.oldValue == "34.00")
        #expect(row.newValue == "update started")
        #expect(row.result == .ok)
        #expect(try await svc.writeBudget().remaining == ChangeBudget.maxChangesPerHour - 1)

        clock.advance(30)
        let downloading = try await svc.firmwareStatus()
        #expect(downloading.phase == .downloading)
        #expect(downloading.isInProgress(now: clock.now))
        #expect(downloading.canCancel)
        #expect(!downloading.canStart)
        // While it runs, MELCloud is asked at most every 15 s.
        let reads = await backend.firmwareReads
        clock.advance(5)
        _ = try await svc.firmwareStatus()
        #expect(await backend.firmwareReads == reads)
        clock.advance(25)
        #expect(try await svc.firmwareStatus().current?.filesDownloaded == 2)
        clock.advance(30)
        #expect(try await svc.firmwareStatus().phase == .resetPending)
        clock.advance(20)
        #expect(try await svc.firmwareStatus().phase == .resetting)
        clock.advance(20)
        let complete = try await svc.firmwareStatus()
        #expect(complete.phase == .complete)
        #expect(!complete.isInProgress(now: clock.now))
        // The snapshot is marked stale so the next status read shows the new version.
        #expect(try store.latestSnapshot()?.stale == true)
        let state = try await svc.currentState()
        #expect(state.state?.firmware.version == "35.00")
        #expect(state.state?.firmware.updateAvailable == false)
        let after = try await svc.firmwareStatus()
        #expect(after.currentVersion == "35.00")
        #expect(after.startProblem?.contains("No firmware update is waiting") == true)
        // Nothing waits any more: no more List2 reads.
        let finalReads = await backend.firmwareReads
        clock.advance(120)
        _ = try await svc.firmwareStatus()
        #expect(await backend.firmwareReads == finalReads)
    }

    @Test func mockUpdateCanBeCancelledAndClaudeCanStartWithApproval() async throws {
        let store = try HistoryStore(path: temporaryDatabasePath())
        let backend = MockBackend(timeZone: .gmt, now: clock.provider)
        let svc = service(backend, store: store)
        _ = try await svc.currentState()
        // Nothing runs yet: cancel is refused and logged.
        let early = try await svc.cancelFirmwareUpdate(source: .app, reason: "x")
        #expect(early.result == .rejected)
        let approver = RecordingApprover(.approved)
        let started = try await svc.startFirmwareUpdate(source: .claude, reason: "Brukeren ba om det", approver: approver)
        #expect(started.result == .ok)
        #expect(approver.received.count == 1)
        #expect(try store.changes(limit: 1).first?.source == .claude)
        clock.advance(30)
        let cancelled = try await svc.cancelFirmwareUpdate(source: .app, reason: "Avbrutt i appen")
        #expect(cancelled.result == .ok)
        #expect(await backend.firmwareCancels == 1)
        #expect(try store.changes(limit: 1).first?.newValue == "update cancelled")
        clock.advance(20)
        let status = try await svc.firmwareStatus()
        #expect(status.phase == .approvalRequired)
        #expect(!status.isInProgress(now: clock.now))
    }
}
