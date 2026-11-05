import Foundation

/// One hour of the whole house's electricity use as Tibber reports it.
public struct HouseHour: Codable, Sendable, Equatable {
    public var hour: Date
    public var kWh: Double
    /// What Tibber says the hour cost (NOK); a cross-check, not used for the app's own cost.
    public var costNok: Double?
    /// Tibber's `unitPrice` in øre/kWh.
    public var unitPriceOre: Double?

    public init(hour: Date, kWh: Double, costNok: Double?, unitPriceOre: Double?) {
        self.hour = hour
        self.kWh = kWh
        self.costNok = costNok
        self.unitPriceOre = unitPriceOre
    }
}

/// A source of the house's hourly consumption.
public protocol HouseConsumptionProviding: Sendable {
    /// The last `lastHours` finished hours (Tibber caps it at 744).
    func fetchConsumption(lastHours: Int) async throws -> [HouseHour]
}

/// Tibber `viewer.homes[].consumption(resolution: HOURLY, last: N)`; nodes `from, to, unitPrice,
/// unitPriceVAT, consumption, cost, currency`. Not real-time: the last hours fill in late.
/// Rate limit about 100 requests per 5 minutes per IP; we ask at most hourly.
public struct TibberConsumptionProvider: HouseConsumptionProviding {
    private let token: String
    private let transport: any HTTPTransport

    public init(token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    static func query(lastHours: Int) -> String {
        let last = min(max(lastHours, 1), 744)
        return "{ viewer { homes { consumption(resolution: HOURLY, last: \(last)) { nodes { from to unitPrice unitPriceVAT consumption cost currency } } } } }"
    }

    public func fetchConsumption(lastHours: Int) async throws -> [HouseHour] {
        var request = URLRequest(url: TibberPriceProvider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Varmepumpe/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(Self.query(lastHours: lastHours))]))
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await transport.send(request) } catch let error as HeatPumpError {
            if case .network(let detail) = error { throw PriceError.network(detail) }
            throw PriceError.network(error.localizedDescription)
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw PriceError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw PriceError.http(status: response.statusCode) }
        return try Self.parse(data)
    }

    /// Hours from the first home with consumption data; hours Tibber has not finished (null) are skipped.
    static func parse(_ data: Data) throws -> [HouseHour] {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw PriceError.decoding("ugyldig JSON") }
        if let errors = json["errors"]?.array, !errors.isEmpty {
            let message = errors.compactMap { $0["message"]?.string }.joined(separator: "; ")
            if message.lowercased().contains("unauthor") || message.lowercased().contains("token") { throw PriceError.unauthorized }
            throw PriceError.server(message)
        }
        let homes = json["data"]?["viewer"]?["homes"]?.array ?? []
        let nodes = homes.compactMap { $0["consumption"]?["nodes"]?.array }.first { !$0.isEmpty } ?? []
        return nodes.compactMap { node in
            guard let from = PriceAggregation.iso(node["from"]?.string), let kWh = node["consumption"]?.double else { return nil }
            return HouseHour(hour: from, kWh: kWh, costNok: node["cost"]?.double, unitPriceOre: node["unitPrice"]?.double.map { $0 * 100 })
        }
    }
}

/// Demo: a household base load with morning and evening peaks plus the simulated heat pump.
public struct MockHouseConsumptionProvider: HouseConsumptionProviding {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func fetchConsumption(lastHours: Int) async throws -> [HouseHour] {
        let current = (now().timeIntervalSince1970 / 3600).rounded(.down) * 3600
        return (1...min(max(lastHours, 1), 744)).map { back -> HouseHour in
            let start = Date(timeIntervalSince1970: current - Double(back) * 3600)
            let hourOfDay = Double(Calendar.current.component(.hour, from: start))
            let base = 0.35 + 0.9 * exp(-pow((hourOfDay - 7.5) / 1.5, 2)) + 1.3 * exp(-pow((hourOfDay - 18) / 2.2, 2))
            let pump = stride(from: 0.0, to: 3600, by: 900).map { MockLocalSimulation.averageW(at: start.addingTimeInterval($0 + 450)) }
                .reduce(0, +) / 4 / 1000
            let kWh = ((base + pump) * 100).rounded() / 100
            let ore = 85 + 35 * sin(start.timeIntervalSince1970 / 86_400 * 0.9) + 40 * exp(-pow((hourOfDay - 18) / 2.0, 2))
            return HouseHour(hour: start, kWh: kWh, costNok: (kWh * ore * 1.25).rounded() / 100, unitPriceOre: ore * 1.25)
        }
    }
}

/// One hour: the house and the heat pump.
public struct HouseShareHour: Codable, Sendable, Equatable {
    public var hour: Date
    public var houseKWh: Double
    public var heatPumpKWh: Double?
    /// True when the heat pump's kWh come from its exact local counter (else an estimate).
    public var heatPumpMeasured: Bool
    public var houseCostNok: Double?

    /// Heat pump ÷ house, or nil without both.
    public var share: Double? {
        guard let heatPumpKWh, houseKWh > 0 else { return nil }
        return heatPumpKWh / houseKWh
    }
}

/// One local day.
public struct HouseShareDay: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd`
    public var day: String
    public var start: Date
    public var houseKWh: Double
    /// Heat-pump kWh over the hours where both are known.
    public var heatPumpKWh: Double
    /// Hours with both house and heat-pump data.
    public var hoursWithBoth: Int
    /// Heat pump ÷ house over the hours with both; nil with fewer than 20 such hours.
    public var share: Double?
    /// True when every heat-pump hour came from the local counter.
    public var heatPumpMeasured: Bool
    /// Tibber's own cost for the whole house that day.
    public var houseCostNok: Double?
}

public struct HouseShareSummary: Codable, Sendable, Equatable {
    public var hours: [HouseShareHour]
    public var days: [HouseShareDay]
    /// Yesterday, when it is in the range.
    public var yesterday: HouseShareDay?
}

public enum HouseShare {
    /// Hours with both values a day needs before a share is given.
    public static let minHoursPerDay = 20

    public static func summarize(
        house: [Date: HouseHour], heatPump: [Date: HourCost], timeZone: TimeZone, yesterday: String? = nil
    ) -> HouseShareSummary {
        let hours = house.keys.sorted().compactMap { hour -> HouseShareHour? in
            guard let h = house[hour] else { return nil }
            let pump = heatPump[hour]
            return HouseShareHour(
                hour: hour, houseKWh: h.kWh, heatPumpKWh: pump?.kWh, heatPumpMeasured: pump?.measuredLocally ?? false,
                houseCostNok: h.costNok)
        }
        let calendar = WireDate.calendar(timeZone)
        let grouped = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.hour) }
        let days = grouped.keys.sorted().map { start -> HouseShareDay in
            let list = grouped[start] ?? []
            let both = list.filter { $0.heatPumpKWh != nil }
            let houseBoth = both.reduce(0) { $0 + $1.houseKWh }
            let pump = both.reduce(0) { $0 + ($1.heatPumpKWh ?? 0) }
            let costs = list.compactMap(\.houseCostNok)
            func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            return HouseShareDay(
                day: WireDate.day(start, timeZone: timeZone), start: start, houseKWh: r(list.reduce(0) { $0 + $1.houseKWh }),
                heatPumpKWh: r(pump), hoursWithBoth: both.count,
                share: both.count >= minHoursPerDay && houseBoth > 0 ? pump / houseBoth : nil,
                heatPumpMeasured: !both.isEmpty && both.allSatisfy(\.heatPumpMeasured),
                houseCostNok: costs.isEmpty ? nil : r(costs.reduce(0, +)))
        }
        return HouseShareSummary(hours: hours, days: days, yesterday: days.first { $0.day == yesterday })
    }
}
