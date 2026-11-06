import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit
@testable import DemoIntegration

/// Approver that records requests and answers with a fixed decision.
final class RecordingApprover: ChangeApprover {
    private let requests = Mutex<[ApprovalRequest]>([])
    let decision: ApprovalDecision

    init(_ decision: ApprovalDecision) { self.decision = decision }

    var received: [ApprovalRequest] { requests.withLock { $0 } }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.withLock { $0.append(request) }
        return decision
    }
}

@Suite("Round 2 review")
struct Round2ReviewTests {
    private func makeService(
        clock: TestClock, backend: CountingBackend, credentials: (any CredentialProviding)? = nil,
        path: String = temporaryDatabasePath()
    ) throws -> HeatPumpService {
        HeatPumpService(
            backend: backend, store: try HistoryStore(path: path), credentials: credentials, timeZone: .gmt,
            now: clock.provider, sleep: clock.sleeper)
    }

    // 1. Claude's writes need approval.
    @Test func approvedChangeIsSent() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try makeService(clock: clock, backend: backend)
        _ = try await svc.currentState()
        let approver = RecordingApprover(.approved)
        let outcomes = try await svc.applyWithApproval(
            [.temperature(21.5)], source: .claude, reason: "Litt kaldt", approver: approver)
        #expect(outcomes.map(\.result) == [.ok])
        #expect(await backend.applyCalls == 1)
        let request = try #require(approver.received.first)
        #expect(request.summaries == ["Change target temperature to 21,5 °C"])
        #expect(request.message.contains("Reason from Claude: Litt kaldt"))
    }

    @Test(arguments: [ApprovalDecision.rejected, .timedOut, .unavailable("ingen grafisk økt på Macen")])
    func refusedChangeIsLoggedAndNotSent(decision: ApprovalDecision) async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let store = try HistoryStore(path: temporaryDatabasePath())
        let svc = HeatPumpService(backend: backend, store: store, timeZone: .gmt, now: clock.provider, sleep: clock.sleeper)
        _ = try await svc.currentState()
        let outcomes = try await svc.applyWithApproval(
            [.power(false)], source: .claude, reason: "Spare strøm", approver: FixedApprover(decision))
        #expect(outcomes.map(\.result) == [.rejected])
        #expect(await backend.applyCalls == 0)
        let row = try #require(try store.changes(limit: 1).first)
        #expect(row.result == .rejected)
        #expect(row.source == .claude)
        #expect(row.reason == "Spare strøm")
        #expect(row.error == decision.rejectionText)
    }

    @Test func invalidChangeIsRejectedWithoutAsking() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try makeService(clock: clock, backend: backend)
        _ = try await svc.currentState()
        let approver = RecordingApprover(.approved)
        let outcomes = try await svc.applyWithApproval([.temperature(40)], source: .claude, reason: "x", approver: approver)
        #expect(outcomes.map(\.result) == [.rejected])
        #expect(approver.received.isEmpty)
    }

    @Test func approvalBypassOnlyWithMockBackend() {
        let interactive = RecordingApprover(.rejected)
        let mockApprove = ApprovalPolicy.approver(
            environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_APPROVAL": "auto-approve"], interactive: interactive)
        #expect((mockApprove as? FixedApprover)?.decision == .approved)
        let mockReject = ApprovalPolicy.approver(
            environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_APPROVAL": "auto-reject"], interactive: interactive)
        #expect((mockReject as? FixedApprover)?.decision == .rejected)
        let real = ApprovalPolicy.approver(environment: ["VARMEPUMPE_APPROVAL": "auto-approve"], interactive: interactive)
        #expect(real is RecordingApprover)
        let unknown = ApprovalPolicy.approver(
            environment: ["VARMEPUMPE_BACKEND": "mock", "VARMEPUMPE_APPROVAL": "yes"], interactive: interactive)
        #expect(unknown is RecordingApprover)
    }

    // 3. No credentials: no slot used; saving them allows one immediate test fetch.
    @Test func missingCredentialsDoNotUseRefreshSlot() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let path = temporaryDatabasePath()
        let svc = try makeService(clock: clock, backend: backend, credentials: InMemoryCredentialStore(), path: path)
        let first = try await svc.currentState(force: true)
        #expect(first.needsLogin)
        #expect(await backend.fetchStateCalls == 0)
        #expect(try HistoryStore(path: path).fetchState(key: "state") == nil)
        clock.advance(5)
        let signedIn = try await svc.signIn(MELCloudCredentials(email: "a@b.no", password: "pw"))
        #expect(signedIn.refreshed)
        #expect(await backend.fetchStateCalls == 1)
    }

    @Test func signInTestFetchIsLimitedAndRespectsBlocks() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let path = temporaryDatabasePath()
        let svc = try makeService(clock: clock, backend: backend, credentials: InMemoryCredentialStore(), path: path)
        let creds = MELCloudCredentials(email: "a@b.no", password: "pw")
        _ = try await svc.signIn(creds)
        clock.advance(3)
        let again = try await svc.signIn(creds)  // within 10 s: no second login
        #expect(!again.refreshed)
        #expect(again.nextRefreshAllowed != nil)
        clock.advance(20)
        try HistoryStore(path: path).recordBlock(until: clock.now.addingTimeInterval(900), reason: .loginThrottled)
        let blocked = try await svc.signIn(creds)
        #expect(!blocked.refreshed)
        #expect(blocked.blockReason == .loginThrottled)
        #expect(await backend.fetchStateCalls == 1)
    }

    // 4. Messages follow the block reason.
    @Test func blockMessagesFollowReason() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let svc = try makeService(clock: clock, backend: backend)
        _ = try await svc.currentState()
        clock.advance(700)
        await backend.failNext(with: .loginThrottled(until: clock.now.addingTimeInterval(17 * 60)))
        let throttled = try await svc.currentState()
        #expect(throttled.blockReason == .loginThrottled)
        #expect(throttled.blockMessage?.contains("Too many login attempts") == true)
        #expect(throttled.blockMessage?.contains("Try again at") == true)
        let change = try await svc.apply(.fanSpeed(2), source: .app, reason: "x")
        #expect(change.message.contains("login attempts"))

        #expect(BlockReason.rateLimited.message(until: clock.now).contains("too much traffic"))
        #expect(BlockReason.unauthorized.message(until: clock.now).contains("refuses access"))
    }

    @Test func invalidCredentialsGetTheirOwnMessage() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let creds = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "feil"))
        let svc = try makeService(clock: clock, backend: backend, credentials: creds)
        await backend.failNext(with: .invalidCredentials(nil))
        let result = try await svc.currentState()
        #expect(result.blockReason == nil)
        #expect(result.blockMessage?.contains("did not accept the email or password") == true)
    }

    // 6. Polling never reads the keychain secret; existence is checked once and cached.
    @Test func credentialPresenceIsCached() async throws {
        let clock = TestClock()
        let backend = CountingBackend(now: clock.provider)
        let creds = InMemoryCredentialStore(credentials: MELCloudCredentials(email: "a@b.no", password: "pw"))
        let svc = try makeService(clock: clock, backend: backend, credentials: creds)
        for _ in 0..<5 {
            _ = try await svc.currentState(force: true)
            #expect(await svc.hasCredentials())
            clock.advance(61)
        }
        #expect(creds.existenceChecks == 1)
        #expect(creds.loadCount == 0)
        try await svc.signOut()
        #expect(await !svc.hasCredentials())
        #expect(creds.existenceChecks == 1)
        try await svc.saveCredentials(MELCloudCredentials(email: "a@b.no", password: "pw"))
        #expect(await svc.hasCredentials())
    }

    // 2. Draft holds only touched fields.
    @Test func controlEditsFollowLiveStateForUntouchedFields() {
        let now = Date()
        var live = ControlSettings(makeState(at: now, set: 21))
        var edits = ControlEdits()
        edits.setTemperature = 22
        #expect(edits.changes(from: live) == [.temperature(22)])
        // Someone else changes the fan and mode; nothing new becomes pending.
        live.fanSpeed = 3
        live.mode = .cool
        #expect(edits.changes(from: live) == [.temperature(22)])
        #expect(edits.displayed(over: live).fanSpeed == 3)
        // Live catches up with the edit: nothing pending, and prune drops it.
        live.setTemperature = 22
        #expect(edits.changes(from: live).isEmpty)
        edits.prune(against: live)
        #expect(edits.isEmpty)
    }

    @Test func controlEditsClampOnlyWhenNeeded() {
        let state = makeState(at: Date(), mode: .heat, set: 12)
        let live = ControlSettings(state)
        var edits = ControlEdits()
        edits.mode = .cool
        edits.clampSetpoint(over: live, limits: state.limits)
        #expect(edits.setTemperature == 16)
        var heatOnly = ControlEdits()
        heatOnly.mode = .heat
        heatOnly.clampSetpoint(over: ControlSettings(makeState(at: Date(), mode: .cool, set: 21)), limits: state.limits)
        #expect(heatOnly.setTemperature == nil)
    }
}
