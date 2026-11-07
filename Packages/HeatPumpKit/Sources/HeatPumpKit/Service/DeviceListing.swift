import Foundation

/// Listing an account's devices for services whose sign-in is a listing (energy meters, air
/// quality sensors): one request under the integration's state spacing (`stateKey`,
/// `minRefreshInterval`) and blocks. Listed devices are registered (new ones enabled); the
/// integration's devices the account no longer lists are disabled. A refused token or 429 is
/// recorded so every process stops asking.
struct DeviceListing: Sendable {
    let connection: any DeviceConnection
    let integration: any Integration
    let store: HistoryStore
    let now: @Sendable () -> Date

    var serviceName: String { integration.displayName }

    func describe(_ error: any Error) -> String {
        if let error = error as? HeatPumpError { return error.description(serviceName: serviceName) }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// One listing when the spacing allows it (nil: nothing sent).
    func refresh() async throws -> [DeviceSummary]? {
        let t = now()
        guard try reserve(minInterval: integration.rateLimitPolicy.minRefreshInterval, now: t) == .allowed else { return nil }
        do {
            return try await listAndRegister(now: t)
        } catch let error as HeatPumpError {
            try handle(error, now: t)
            throw error
        }
    }

    /// The sign-in's listing (spaced by `minInterval`), as a `StateResult` without a state.
    func signInListing(minInterval: TimeInterval) async throws -> StateResult {
        let t = now()
        switch try reserve(minInterval: minInterval, now: t) {
        case .allowed:
            do {
                let listed = try await listAndRegister(now: t)
                guard !listed.isEmpty else { return result(error: describe(HeatPumpError.deviceNotFound)) }
                return StateResult(state: nil, refreshed: true, stale: false)
            } catch let error as HeatPumpError {
                try handle(error, now: t)
                var r = result(error: describe(error.isCredentialProblem ? HeatPumpError.credentialsRejected : error))
                r.needsLogin = error.isCredentialProblem || error == .missingCredentials
                return r
            }
        case .throttled(let next):
            return StateResult(state: nil, refreshed: false, stale: true, nextRefreshAllowed: next)
        case .blocked(let until):
            var r = result(error: nil)
            r.blockedUntil = until
            r.blockMessage = BlockReason.rateLimited.message(until: until, serviceName: serviceName)
            return r
        case .credentialsRejected:
            var r = result(error: describe(HeatPumpError.credentialsRejected))
            r.needsLogin = true
            return r
        }
    }

    private func listAndRegister(now t: Date) async throws -> [DeviceSummary] {
        let listed = try await connection.listDevices()
        try store.syncDevices(listed, integration: integration.id)
        try store.recordFetchSuccess(key: HistoryStore.fetchKey(HeatPumpService.stateKey, integration: integration.id), now: t)
        return listed
    }

    private func result(error: String?) -> StateResult {
        StateResult(state: nil, refreshed: false, stale: true, error: error)
    }

    private func reserve(minInterval: TimeInterval, now: Date) throws -> FetchDecision {
        try store.reserveFetch(
            key: HistoryStore.fetchKey(HeatPumpService.stateKey, integration: integration.id), minInterval: minInterval, now: now,
            blockingIntegration: integration.id)
    }

    /// Records a block for too much traffic or for access refused after a fresh sign-in, and stops
    /// every request after refused values until new ones are saved (never retried with the same
    /// values).
    func handle(_ error: HeatPumpError, now: Date) throws {
        switch error {
        case .rateLimited(let until): try store.recordBlock(until: until, reason: .rateLimited, integration: integration.id)
        case .invalidCredentials, .credentialsRejected: try store.recordCredentialsRejected(now: now, integration: integration.id)
        case .unauthorized:
            try store.recordBlock(
                until: now.addingTimeInterval(integration.rateLimitPolicy.unauthorizedBlock), reason: .unauthorized, integration: integration.id)
        default: break
        }
    }
}
