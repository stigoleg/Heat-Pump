import Foundation

/// Norwegian electricity price areas.
public enum PriceArea: String, Codable, Sendable, CaseIterable {
    case no1 = "NO1", no2 = "NO2", no3 = "NO3", no4 = "NO4", no5 = "NO5"

    public var displayName: String {
        switch self {
        case .no1: "NO1 – Øst-Norge"
        case .no2: "NO2 – Sør-Norge"
        case .no3: "NO3 – Midt-Norge"
        case .no4: "NO4 – Nord-Norge"
        case .no5: "NO5 – Vest-Norge"
        }
    }

    /// VAT on electricity: 25 %, except Nord-Norge (NO4), which is exempt.
    public var vatFactor: Double { self == .no4 ? 1.0 : 1.25 }
}

/// Which kind of electricity agreement the household has.
public enum PriceAgreementKind: String, Codable, Sendable, CaseIterable {
    /// Fixed state price per kWh (no strømstøtte).
    case norgespris
    /// Spot price from the user's Tibber account.
    case tibber
    /// Spot price from hvakosterstrommen.no plus the supplier's markup.
    case spot

    public var displayName: String {
        switch self {
        case .norgespris: "Norgespris"
        case .tibber: "Spotpris via Tibber"
        case .spot: "Spotpris uten Tibber"
        }
    }
}

/// Grid tariff energy component (energiledd), øre/kWh incl. VAT and fees.
public struct GridTariff: Codable, Sendable, Equatable {
    /// Weekdays 06–22.
    public var dayOre: Double
    /// Weekdays 22–06, weekends and public holidays.
    public var nightOre: Double

    public init(dayOre: Double, nightOre: Double) {
        self.dayOre = dayOre
        self.nightOre = nightOre
    }

    /// Elvia standard tariff for households from 1 July 2026: day 46,40 and night/weekend
    /// 31,40 øre/kWh, "inklusive alle avgifter" (Enova 1,0 øre, elavgift 7,13 øre and 25 % VAT).
    /// Source: https://www.elvia.no/siteassets/dokumenter/priser/2026/1-juli-2026/tariffblad_1_0_standard-tariff_privat_20260701.pdf
    /// (read 2026-11-05). The fixed capacity part (fastledd) is left out on purpose.
    public static let elvia2026 = GridTariff(dayOre: 46.40, nightOre: 31.40)
    public static let elviaSource = "Elvia, standard nettleie for husholdninger"
    public static let elviaAsOf = "1. juli 2026"
}

/// State electricity support for households on spot agreements (strømstøtte).
public enum Stromstotte {
    /// 2026 threshold: 77 øre/kWh excl. VAT (96,25 øre incl. 25 % VAT); raised from 75 øre on
    /// 1 January 2026. Source: regjeringen.no "Regjeringens strømtiltak"
    /// (https://www.regjeringen.no/no/tema/energi/stromstotte/id2900232/), checked 2026-11-05.
    public static let thresholdOreExVat = 77.0
    /// The state covers 90 % of the hourly spot price above the threshold.
    public static let coverage = 0.9

    /// Support in øre/kWh incl. VAT for one hour (positive number; it is subtracted from the price).
    public static func support(spotOreExVat: Double, vatFactor: Double) -> Double {
        coverage * max(0, spotOreExVat - thresholdOreExVat) * vatFactor
    }
}

/// User's price settings. Shared between processes through the database.
public struct PriceSettings: Codable, Sendable, Equatable {
    public var agreement: PriceAgreementKind
    /// Norgespris in øre/kWh incl. VAT.
    public var norgesprisOre: Double
    /// Price area for spot without Tibber.
    public var area: PriceArea
    /// Supplier markup in øre/kWh incl. VAT (spot without Tibber).
    public var markupOre: Double
    public var grid: GridTariff

    public init(
        agreement: PriceAgreementKind = .norgespris, norgesprisOre: Double = 50, area: PriceArea = .no1,
        markupOre: Double = 0, grid: GridTariff = .elvia2026
    ) {
        self.agreement = agreement
        self.norgesprisOre = norgesprisOre
        self.area = area
        self.markupOre = markupOre
        self.grid = grid
    }

    public static let `default` = PriceSettings()
}

/// Spot price for one hour as stored in `price_hourly`.
public struct HourPrice: Codable, Sendable, Equatable {
    /// Start of the hour.
    public var hour: Date
    /// Price area (`NO1`…) or `tibber` for the user's Tibber home.
    public var area: String
    /// `tibber`, `hvakosterstrommen` or `mock`.
    public var source: String
    /// Spot price excl. VAT, øre/kWh.
    public var spotOre: Double
    /// Spot price incl. VAT (Tibber: `total`), øre/kWh.
    public var totalOre: Double

    public init(hour: Date, area: String, source: String, spotOre: Double, totalOre: Double) {
        self.hour = hour
        self.area = area
        self.source = source
        self.spotOre = spotOre
        self.totalOre = totalOre
    }
}

/// What one kWh costs in a given hour, split into parts (øre/kWh incl. VAT).
public struct PriceBreakdown: Codable, Sendable, Equatable {
    public var hour: Date
    /// Electricity: Norgespris, or spot incl. VAT plus markup.
    public var energyOre: Double
    /// Grid tariff energy part for this hour.
    public var gridOre: Double
    /// Strømstøtte, zero or negative.
    public var supportOre: Double
    public var totalOre: Double { energyOre + gridOre + supportOre }
    /// True when the grid tariff uses the day rate this hour.
    public var isDayRate: Bool

    public init(hour: Date, energyOre: Double, gridOre: Double, supportOre: Double, isDayRate: Bool) {
        self.hour = hour
        self.energyOre = energyOre
        self.gridOre = gridOre
        self.supportOre = supportOre
        self.isDayRate = isDayRate
    }
}

/// Cost in NOK split like the electricity bill.
public struct CostSplit: Codable, Sendable, Equatable {
    public var energyNok: Double
    public var gridNok: Double
    /// Zero or negative.
    public var supportNok: Double
    public var totalNok: Double { energyNok + gridNok + supportNok }

    public init(energyNok: Double = 0, gridNok: Double = 0, supportNok: Double = 0) {
        self.energyNok = energyNok
        self.gridNok = gridNok
        self.supportNok = supportNok
    }

    public static func + (a: CostSplit, b: CostSplit) -> CostSplit {
        CostSplit(energyNok: a.energyNok + b.energyNok, gridNok: a.gridNok + b.gridNok, supportNok: a.supportNok + b.supportNok)
    }

    /// `kWh` at `price` (øre/kWh).
    public init(kWh: Double, price: PriceBreakdown) {
        self.init(
            energyNok: kWh * price.energyOre / 100, gridNok: kWh * price.gridOre / 100,
            supportNok: kWh * price.supportOre / 100)
    }

    public func rounded() -> CostSplit {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return CostSplit(energyNok: r(energyNok), gridNok: r(gridNok), supportNok: r(supportNok))
    }
}

/// Price data for one hour of energy use.
public struct HourCost: Codable, Sendable, Equatable {
    public var hour: Date
    public var kWh: Double
    public var cost: CostSplit?
    /// True when the kWh come from the adapter's exact local counter (else MELCloud's counter).
    public var measuredLocally: Bool = false
}
