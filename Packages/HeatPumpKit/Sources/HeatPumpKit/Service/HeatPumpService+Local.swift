import Foundation

/// Read-only local diagnostics from the Wi-Fi adapter. Control always goes through MELCloud.
///
/// Polite polling, across processes: at most one request per 20 s (`fetch_state` key `local`),
/// 5 s timeout, and after failures a back-off of 2, 4, 8 and then 10 minutes.
extension HeatPumpService {
    static let localSettingsKey = "localConnection"
    static let localStatusKey = "localStatus"
    public static let localFetchKey = "local"
    static let localDiscoveryKey = "local.discovery"
    static let localAutoDiscoveryKey = "local.autodiscovery"
    static let localPruneKey = "local.prune"
    /// Shortest gap between two reads of the adapter.
    public static let localMinInterval: TimeInterval = 20
    /// Automatic re-discovery after the IP stops answering, at most this often.
    public static let localRediscoveryInterval: TimeInterval = 3600
    /// Failures in a row before automatic re-discovery is tried.
    static let localRediscoveryAfterFailures = 3

    /// Spacing before the next read after `failures` consecutive failures.
    public static func localBackoff(failures: Int) -> TimeInterval {
        switch failures {
        case ...0: localMinInterval
        case 1: 2 * 60
        case 2: 4 * 60
        case 3: 8 * 60
        default: 10 * 60
        }
    }

    // MARK: Settings

    public func localSettings() throws -> LocalSettings {
        try store.setting(LocalSettings.self, key: Self.localSettingsKey) ?? .default
    }

    /// Saves the settings. A host that is not a private IPv4 address is refused.
    public func saveLocalSettings(_ settings: LocalSettings) throws {
        var clean = settings
        if let host = settings.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty {
            guard let valid = LocalSmartClient.validatedHost(host) else {
                throw HeatPumpError.validation(LocalAccessError.invalidHost(host).errorDescription ?? "")
            }
            clean.host = valid
        } else {
            clean.host = nil
        }
        let previous = try localSettings()
        try store.saveSetting(clean, key: Self.localSettingsKey)
        if previous.host != clean.host || !previous.enabled {
            // A new address or a fresh start: forget the old failures and back-off.
            try store.saveSetting(LocalStatusRecord(), key: Self.localStatusKey)
        }
    }

    func localStatusRecord() throws -> LocalStatusRecord {
        try store.setting(LocalStatusRecord.self, key: Self.localStatusKey) ?? LocalStatusRecord()
    }

    public func localReachability() throws -> LocalReachability {
        let settings = try localSettings()
        let record = try localStatusRecord()
        let fetch = try store.fetchState(key: Self.localFetchKey)
        let next = fetch?.lastAttempt.map { $0.addingTimeInterval(Self.localBackoff(failures: record.consecutiveFailures)) }
        return LocalReachability(
            enabled: settings.enabled, host: settings.host, lastAttempt: fetch?.lastAttempt, lastSuccess: fetch?.lastSuccess,
            consecutiveFailures: record.consecutiveFailures, failingSince: record.failingSince, lastError: record.lastError,
            nextAttemptAllowed: next.flatMap { $0 > now() ? $0 : nil }, onHomeNetwork: settings.host.map(isOnNetwork))
    }

    /// True when the Mac is on the /24 of `host` right now. Away from home every read would fail,
    /// and the saved address may belong to some other device there, so automatic reads and
    /// re-discovery pause.
    func isOnNetwork(_ host: String) -> Bool {
        guard let wanted = subnet24(host) else { return false }
        return local.currentSubnets().contains(wanted)
    }

    static let awayMessage = "Ikke på hjemmenettet. Lokal avlesning er satt på pause til Macen er tilbake på samme nett som varmepumpen."

    // MARK: Reading

    enum LocalRead {
        case sample(LocalSample)
        case throttled(nextAllowed: Date?)
        case failed(String)
    }

    /// One read of `host` if the cross-process spacing allows it. With `persist` (the saved
    /// address) the reading is stored and success/failure is recorded; a test of another
    /// address leaves both the history and the failure state alone.
    func readLocal(host: String, minInterval: TimeInterval, persist: Bool = true) async throws -> LocalRead {
        let t = now()
        switch try store.reserveFetch(key: Self.localFetchKey, minInterval: minInterval, now: t, melcloud: false) {
        case .throttled(let next):
            return .throttled(nextAllowed: next)
        case .blocked, .credentialsRejected:
            return .throttled(nextAllowed: nil)  // not used for local keys
        case .allowed:
            do {
                let reply = try await local.makeClient(host).readStatus()
                let parsed = CN105Parser.sample(reply: reply, at: now())
                guard parsed.used > 0 else { throw LocalAccessError.noFrames }
                guard persist else { return .sample(parsed.sample) }
                try store.insertLocalSample(parsed.sample)
                try store.recordFetchSuccess(key: Self.localFetchKey, now: t)
                try store.saveSetting(LocalStatusRecord(), key: Self.localStatusKey)
                try pruneLocalIfDue()
                return .sample(parsed.sample)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                guard persist else { return .failed(message) }
                var record = try localStatusRecord()
                record.consecutiveFailures += 1
                record.failingSince = record.failingSince ?? t
                record.lastError = message
                try store.saveSetting(record, key: Self.localStatusKey)
                return .failed(message)
            }
        }
    }

    private func pruneLocalIfDue() throws {
        guard try store.reserveFetch(key: Self.localPruneKey, minInterval: 86_400, now: now(), melcloud: false) == .allowed
        else { return }
        try store.pruneLocalSamples(now: now())
    }

    /// Latest local reading. Reads the adapter only when local access is on and the newest stored
    /// reading is older than `maxAge` (and the 20 s spacing / back-off allow it).
    public func liveStatus(maxAge: TimeInterval = 60) async throws -> LiveStatus {
        let settings = try localSettings()
        var latest = try store.latestLocalSample()
        var refreshed = false
        var message: String?
        let fresh = latest.map { now().timeIntervalSince($0.timestamp) < maxAge } ?? false
        if !settings.enabled {
            message = LocalAccessError.notEnabled.errorDescription
        } else if !fresh {
            if let host = settings.host, !isOnNetwork(host) {
                message = Self.awayMessage
            } else if let host = settings.host {
                let record = try localStatusRecord()
                switch try await readLocal(host: host, minInterval: Self.localBackoff(failures: record.consecutiveFailures)) {
                case .sample(let sample):
                    latest = sample
                    refreshed = true
                case .throttled:
                    latest = try store.latestLocalSample()  // another process may have just read
                case .failed(let text):
                    message = text
                    try await rediscoverIfDue()
                }
            } else {
                message = LocalAccessError.missingHost.errorDescription
            }
        }
        return LiveStatus(
            sample: latest, ageSeconds: latest.map { max(0, Int(now().timeIntervalSince($0.timestamp))) },
            refreshed: refreshed, reachability: try localReachability(), message: message)
    }

    /// Latest stored reading and reachability. Never contacts the adapter.
    public func storedLiveStatus() throws -> LiveStatus {
        let latest = try store.latestLocalSample()
        return LiveStatus(
            sample: latest, ageSeconds: latest.map { max(0, Int(now().timeIntervalSince($0.timestamp))) }, refreshed: false,
            reachability: try localReachability(), message: nil)
    }

    /// "Test" in Settings: one read of `host` (spacing still applies), without saving the address.
    public func testLocal(host: String) async throws -> LocalTestResult {
        guard let valid = LocalSmartClient.validatedHost(host) else {
            return LocalTestResult(ok: false, message: LocalAccessError.invalidHost(host).errorDescription ?? "", sample: nil)
        }
        let saved = try localSettings().host
        switch try await readLocal(host: valid, minInterval: Self.localMinInterval, persist: valid == saved) {
        case .sample(let sample):
            return LocalTestResult(ok: true, message: Self.describe(sample), sample: sample)
        case .throttled(let next):
            return LocalTestResult(
                ok: false,
                message: "Modulen ble nettopp spurt. Prøv igjen" + (next.map { " etter \(Norwegian.time($0))" } ?? " om litt") + ".",
                sample: nil)
        case .failed(let text):
            return LocalTestResult(ok: false, message: text, sample: nil)
        }
    }

    static func describe(_ s: LocalSample) -> String {
        var parts = ["Kontakt med Wi-Fi-modulen."]
        if let version = s.adapterVersion { parts.append("Fastvare \(version).") }
        if let rssi = s.rssi { parts.append("Signal \(rssi) dBm.") }
        if let watts = s.powerW { parts.append("Effekt \(watts) W.") }
        if let room = s.roomTemperature { parts.append(Norwegian.format("Inne %.1f °C.", room)) }
        if let outdoor = s.outdoorTemperature { parts.append(Norwegian.format("Ute %.1f °C.", outdoor)) }
        return parts.joined(separator: " ")
    }

    // MARK: Discovery

    /// "Finn automatisk": tries the saved address, then looks for the unit's hardware address
    /// (from the MELCloud listing; never shown) on the Mac's own /24. At most once per minute.
    public func discoverLocal() async throws -> LocalDiscoveryResult {
        guard try store.reserveFetch(key: Self.localDiscoveryKey, minInterval: 60, now: now(), melcloud: false) == .allowed else {
            return LocalDiscoveryResult(host: nil, message: "Søket ble nettopp kjørt. Vent et minutt før du prøver igjen.")
        }
        return try await discover()
    }

    /// Re-discovery after repeated failures (the router may have given the unit a new address), at most hourly.
    func rediscoverIfDue() async throws {
        let record = try localStatusRecord()
        guard let host = try localSettings().host, isOnNetwork(host),
            record.consecutiveFailures >= Self.localRediscoveryAfterFailures,
            try store.reserveFetch(
                key: Self.localAutoDiscoveryKey, minInterval: Self.localRediscoveryInterval, now: now(), melcloud: false)
                == .allowed
        else { return }
        _ = try await discover(trySaved: false)
    }

    private func discover(trySaved: Bool = true) async throws -> LocalDiscoveryResult {
        var settings = try localSettings()
        if trySaved, let saved = settings.host,
            case .sample = try await readLocal(host: saved, minInterval: Self.localMinInterval)
        {
            return LocalDiscoveryResult(host: saved, message: "Modulen svarer på \(saved).")
        }
        guard let mac = try cloudMAC() else {
            return LocalDiscoveryResult(
                host: nil,
                message: "Fant ikke maskinvareadressen til varmepumpen i MELCloud ennå. Hent status først, eller skriv inn IP-adressen selv (står i ruterens liste over enheter).")
        }
        let hosts = try await local.scanner.hosts(matchingMAC: mac)
        guard let host = hosts.first(where: { LocalSmartClient.validatedHost($0) != nil }) else {
            return LocalDiscoveryResult(
                host: nil,
                message: "Fant ikke varmepumpen på hjemmenettet. Sjekk at Macen er på samme nett, eller skriv inn IP-adressen fra ruteren.")
        }
        settings.host = host
        try saveLocalSettings(settings)
        if case .sample = try await readLocal(host: host, minInterval: Self.localMinInterval) {
            return LocalDiscoveryResult(host: host, message: "Fant varmepumpen på \(host), og den svarer.")
        }
        return LocalDiscoveryResult(host: host, message: "Fant varmepumpen på \(host). Den leses ved neste oppdatering.")
    }

    /// The unit's MAC from the latest MELCloud data (snapshot, else the stored listing). Internal only.
    private func cloudMAC() throws -> String? {
        if let mac = try store.latestSnapshot()?.state.macAddress, normalizedMAC(mac) != nil { return mac }
        guard let deviceId = try store.latestSnapshot()?.state.deviceId,
            let listing = try store.rawDevice(deviceId: deviceId)?.listing
        else { return nil }
        let mac = listing["Device"]?["MacAddress"]?.string ?? listing["MacAddress"]?.string
        return mac.flatMap { normalizedMAC($0) != nil ? $0 : nil }
    }

    // MARK: History

    public func localSamples(from: Date, to: Date) throws -> [LocalSample] {
        try store.localSamples(from: from, to: to)
    }

    /// Compressor starts per hour (stopped → running between readings ≤ 5 min apart), from SQL.
    public func compressorStarts(from: Date, to: Date) throws -> [HourStarts] {
        try store.localPowerBuckets(from: from, to: to, bucketSeconds: 3600).map {
            HourStarts(hour: $0.start, starts: $0.starts, observedMinutes: min(60, $0.observedSeconds / 60))
        }
    }

    /// Readings aggregated per `bucket` seconds (UTC-aligned), for charts. Computed in SQL.
    public func localPowerBuckets(from: Date, to: Date, bucket: TimeInterval) throws -> [LocalPowerBucket] {
        try store.localPowerBuckets(from: from, to: to, bucketSeconds: max(60, Int(bucket)))
    }

    /// One aggregate over the whole range (totals for KPIs), or nil without readings.
    public func localTotals(from: Date, to: Date) throws -> LocalPowerBucket? {
        let seconds = max(1, Int(to.timeIntervalSince(from).rounded(.up)))
        return try store.localPowerBuckets(from: from, to: to, bucketSeconds: seconds, origin: from).first
    }

    /// Most points `history` returns for a local metric; longer ranges are averaged per bucket.
    static let maxLocalHistoryPoints = 1500

    func localHistory(metric: HistoryMetric, from: Date, to: Date) throws -> [HistoryPoint] {
        if metric == .defrost {
            // Per hour: minutes spent defrosting, and how many defrosts started.
            return try localPowerBuckets(from: from, to: to, bucket: 3600).compactMap { b in
                guard b.phaseCount > 0 else { return nil }
                return HistoryPoint(
                    timestamp: b.start, value: (b.defrostSeconds / 6).rounded() / 10, text: "\(b.defrosts) avriminger",
                    source: "local")
            }
        }
        if try store.localSampleCount(from: from, to: to) <= Self.maxLocalHistoryPoints {
            return try store.localSamples(from: from, to: to).compactMap { s in
                let value = metric == .powerW ? s.powerW : s.compressorHz
                return value.map { HistoryPoint(timestamp: s.timestamp, value: Double($0), text: nil, source: "local") }
            }
        }
        let bucket = max(60, (to.timeIntervalSince(from) / Double(Self.maxLocalHistoryPoints)).rounded(.up))
        return try localPowerBuckets(from: from, to: to, bucket: bucket).compactMap { b in
            (metric == .powerW ? b.averageW : b.averageHz).map {
                HistoryPoint(timestamp: b.start, value: ($0 * 10).rounded() / 10, text: nil, source: "local")
            }
        }
    }

    /// Stretches of running, rest, defrost, start-up and off from local readings (for charts).
    public func localPhaseSpans(from: Date, to: Date) throws -> [LocalPhaseSpan] {
        try store.localPhaseSpans(from: from, to: to)
    }

    /// `get_live_status`: latest reading, starts in the last 1/3/24 h and power over the last hour.
    public func liveSummary(maxAge: TimeInterval = 60) async throws -> LiveSummary {
        let live = try await liveStatus(maxAge: maxAge)
        let t = now()
        func totals(_ seconds: TimeInterval) throws -> LocalPowerBucket? { try localTotals(from: t.addingTimeInterval(-seconds), to: t) }
        let hour = try totals(3600)
        let day = try totals(86_400)
        let stats = hour.flatMap { h -> LiveSummary.PowerStats? in
            guard let average = h.averageW, let low = h.minW, let high = h.maxW else { return nil }
            return LiveSummary.PowerStats(minW: Int(low), averageW: Int(average.rounded()), maxW: Int(high), readings: h.count)
        }
        return LiveSummary(
            live: live, startsLastHour: hour?.starts ?? 0, startsLast3Hours: try totals(3 * 3600)?.starts ?? 0,
            startsLast24Hours: day?.starts ?? 0, observedHoursLast24: ((day?.observedSeconds ?? 0) / 360).rounded() / 10,
            powerLast60Minutes: stats, defrostsLast24Hours: day.flatMap { $0.phaseCount > 0 ? $0.defrosts : nil },
            defrostMinutesLast24Hours: day.flatMap { $0.phaseCount > 0 ? ($0.defrostSeconds / 6).rounded() / 10 : nil })
    }

    /// Hourly aggregates for the health rules (16 days, computed in SQL), or nil when local
    /// access was never used.
    func localHealthInput(now t: Date) throws -> LocalHealthInput? {
        let settings = try localSettings()
        let latest = try store.latestLocalSample()
        guard settings.enabled || latest != nil else { return nil }
        let reach = try localReachability()
        return try LocalHealth.input(
            store: store, now: t, enabled: settings.enabled, onHomeNetwork: reach.onHomeNetwork ?? false, latest: latest,
            lastAttempt: reach.lastAttempt, lastSuccess: reach.lastSuccess, failingSince: reach.failingSince)
    }

    // MARK: Energy from the local counter

    /// Hourly kWh from the local counter and the seconds of each hour it covers exactly.
    func localHourly(from: Date, to: Date) throws -> [Date: (kWh: Double, covered: TimeInterval)] {
        let readings = try store.localCounterReadings(from: from.addingTimeInterval(-LocalCounter.maxExactGap), to: to)
        return LocalCounter.hourly(readings, timeZone: timeZone).filter { $0.key >= from && $0.key < to }
    }

    /// kWh per day (`yyyy-MM-dd`) for days the local counter covers completely (up to now for
    /// today), allowing 15 minutes without exact coverage.
    func localDayTotals(from: Date, to: Date) throws -> [String: Double] {
        let calendar = WireDate.calendar(timeZone)
        let start = calendar.startOfDay(for: from)
        let hourly = try localHourly(from: start, to: min(to, now()).addingTimeInterval(3600))
        guard !hourly.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        var day = start
        let t = now()
        while day < to, day < t {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let hours = hourly.filter { $0.key >= day && $0.key < next }
            let covered = hours.values.reduce(0) { $0 + $1.covered }
            let wanted = min(next, t).timeIntervalSince(day)
            if covered >= wanted - 15 * 60 {
                result[WireDate.day(day, timeZone: timeZone)] = (hours.values.reduce(0) { $0 + $1.kWh } * 100).rounded() / 100
            }
            day = next
        }
        return result
    }
}
