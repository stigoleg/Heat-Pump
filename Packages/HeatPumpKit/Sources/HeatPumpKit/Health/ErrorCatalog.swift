import Foundation

/// How much we trust an error-code explanation.
public enum CatalogConfidence: String, Codable, Sendable {
    /// Text that MELCloud itself returned.
    case melcloud
    /// From a Mitsubishi document for a closely related model.
    case medium
    /// Generic Mitsubishi code or community knowledge, not confirmed for MSZ-RW.
    case low
    /// Nothing known.
    case unknown
}

public struct ErrorCatalogEntry: Codable, Sendable, Equatable {
    public var code: String
    public var title: String
    public var explanation: String
    public var recommendation: String
    public var confidence: CatalogConfidence
    public var source: String

    public init(code: String, title: String, explanation: String, recommendation: String, confidence: CatalogConfidence, source: String) {
        self.code = code
        self.title = title
        self.explanation = explanation
        self.recommendation = recommendation
        self.confidence = confidence
        self.source = source
    }
}

/// Error-code lookups. There is no authoritative MSZ-RW code table available; every
/// entry carries a `confidence` and the caveat is repeated in the user-facing text.
public enum ErrorCatalog {
    public static let caveat =
        L10n.tr("Note: Mitsubishi has no public error code table for MSZ-RW in MELCloud. The explanation comes from related models and may be imprecise.")

    static let callDealer = L10n.tr("Call the dealer or installer and give them the error code and the time.")

    /// Numeric `ErrorCode` values seen from MELCloud Classic.
    static let numeric: [Int: ErrorCatalogEntry] = [
        8000: ErrorCatalogEntry(
            code: "8000", title: L10n.tr("No error"),
            explanation: L10n.tr("MELCloud uses 8000 for “no error” on air-to-air units."),
            recommendation: L10n.tr("No action."), confidence: .medium, source: L10n.tr("Observed in pymelcloud/Home Assistant")),
        0: ErrorCatalogEntry(
            code: "0", title: L10n.tr("No error"), explanation: L10n.tr("No error reported."), recommendation: L10n.tr("No action."),
            confidence: .medium, source: "MELCloud"),
        5101: ErrorCatalogEntry(
            code: "5101", title: L10n.tr("Possible fault in the room temperature sensor"),
            explanation: L10n.tr("In Mitsubishi's general 4-digit codes, 5101 means a fault in the intake/room temperature sensor. Not confirmed for MSZ-RW."),
            recommendation: callDealer, confidence: .low, source: L10n.tr("Mitsubishi general check codes (other series)")),
        5102: ErrorCatalogEntry(
            code: "5102", title: L10n.tr("Possible fault in the indoor unit pipe sensor"),
            explanation: L10n.tr("In Mitsubishi's general 4-digit codes, 5102 means a fault in the liquid pipe sensor. Not confirmed for MSZ-RW."),
            recommendation: callDealer, confidence: .low, source: L10n.tr("Mitsubishi general check codes (other series)")),
        6840: ErrorCatalogEntry(
            code: "6840", title: L10n.tr("Possible communication error between the indoor and outdoor unit"),
            explanation: L10n.tr("In Mitsubishi's general codes, 6840 is used for indoor/outdoor communication errors. Not confirmed for MSZ-RW."),
            recommendation: L10n.format("Switch off the circuit breaker for the heat pump for one minute and switch it back on. If the error comes back: %@", callDealer),
            confidence: .low, source: L10n.tr("Mitsubishi general check codes (other series)")),
    ]

    /// Operation-indicator blink codes from the MSZ-LN service manual (OBH766H §10-4),
    /// the closest related document available. MSZ-RW's own manual (OBH902C) was not obtained.
    public static let blinkCodes: [Int: ErrorCatalogEntry] = [
        1: blink(1, L10n.tr("Miswiring or serial signal"), L10n.tr("The indoor unit receives no signal from the outdoor unit.")),
        2: blink(2, L10n.tr("Indoor unit temperature sensor"), L10n.tr("The pipe sensor or room temperature sensor is short-circuited or open.")),
        3: blink(3, L10n.tr("Indoor unit fan motor"), L10n.tr("The fan motor gives no speed signal.")),
        4: blink(4, L10n.tr("Indoor unit control board"), L10n.tr("The control board cannot read its memory.")),
        5: blink(5, L10n.tr("Outdoor unit power system"), L10n.tr("The compressor has stopped for overcurrent or a start-up failure three times in a row.")),
        6: blink(6, L10n.tr("Outdoor unit temperature sensors"), L10n.tr("A sensor in the outdoor unit is short-circuited or open.")),
        7: blink(7, L10n.tr("Outdoor unit control board"), L10n.tr("The outdoor unit control board cannot read its memory.")),
        14: blink(14, L10n.tr("Other error (14 blinks or more)"), L10n.tr("Another error was detected, for example in sensors or valves. Do not restart until it has been repaired.")),
    ]

    private static func blink(_ count: Int, _ title: String, _ explanation: String) -> ErrorCatalogEntry {
        ErrorCatalogEntry(
            code: "blink-\(count)",
            title: count == 1 ? L10n.format("Blinks steadily: %@", title) : L10n.format("%lld blinks: %@", count, title),
            explanation: explanation,
            recommendation: L10n.tr("Stop using the heat pump and call the dealer (the manual says so when the operation lamp blinks)."),
            confidence: .medium, source: L10n.tr("MSZ-LN service manual OBH766H §10-4 (related model)"))
    }

    /// Whether the catalog has its own explanation for a numeric code.
    public static func hasExplanation(errorCode: Int?) -> Bool {
        errorCode.map { numeric[$0] != nil } ?? false
    }

    /// Looks up an error. MELCloud's own `message` text wins when present.
    public static func lookup(errorCode: Int?, message: String? = nil) -> ErrorCatalogEntry {
        if let message, !message.isEmpty {
            let known = errorCode.flatMap { numeric[$0] }
            return ErrorCatalogEntry(
                code: errorCode.map(String.init) ?? "melding",
                title: message,
                explanation: known.map { L10n.format("The text comes directly from MELCloud. Possible interpretation: %@", $0.explanation) }
                    ?? L10n.tr("The text comes directly from MELCloud."),
                recommendation: known?.recommendation ?? callDealer,
                confidence: .melcloud, source: "MELCloud")
        }
        if let errorCode, let entry = numeric[errorCode] { return entry }
        return ErrorCatalogEntry(
            code: errorCode.map(String.init) ?? "ukjent",
            title: errorCode.map { L10n.format("Unknown error code %@", String($0)) } ?? L10n.tr("Unknown error code"),
            explanation: L10n.format("We have no reliable explanation of this code for MSZ-RW. %@", caveat),
            recommendation: callDealer, confidence: .unknown, source: "—")
    }
}
