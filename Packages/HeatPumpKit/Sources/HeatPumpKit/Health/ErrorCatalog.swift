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
        "Merk: Mitsubishi har ingen offentlig feilkodetabell for MSZ-RW i MELCloud. Forklaringen er hentet fra beslektede modeller og kan være upresis."

    static let callDealer = "Ring forhandleren/installatøren og oppgi feilkoden og tidspunktet."

    /// Numeric `ErrorCode` values seen from MELCloud Classic.
    static let numeric: [Int: ErrorCatalogEntry] = [
        8000: ErrorCatalogEntry(
            code: "8000", title: "Ingen feil",
            explanation: "MELCloud bruker 8000 for «ingen feil» på luft-til-luft-enheter.",
            recommendation: "Ingen tiltak.", confidence: .medium, source: "Observert i pymelcloud/Home Assistant"),
        0: ErrorCatalogEntry(
            code: "0", title: "Ingen feil", explanation: "Ingen feil rapportert.", recommendation: "Ingen tiltak.",
            confidence: .medium, source: "MELCloud"),
        5101: ErrorCatalogEntry(
            code: "5101", title: "Mulig feil på romtemperaturføler",
            explanation: "I Mitsubishis generelle 4-sifrede koder betyr 5101 feil på inntaks-/romtemperaturføleren. Ikke bekreftet for MSZ-RW.",
            recommendation: callDealer, confidence: .low, source: "Mitsubishi generelle kontrollkoder (andre serier)"),
        5102: ErrorCatalogEntry(
            code: "5102", title: "Mulig feil på rørføler i innedelen",
            explanation: "I Mitsubishis generelle 4-sifrede koder betyr 5102 feil på væskerørføleren. Ikke bekreftet for MSZ-RW.",
            recommendation: callDealer, confidence: .low, source: "Mitsubishi generelle kontrollkoder (andre serier)"),
        6840: ErrorCatalogEntry(
            code: "6840", title: "Mulig kommunikasjonsfeil mellom innedel og utedel",
            explanation: "I Mitsubishis generelle koder brukes 6840 om kommunikasjonsfeil inne/ute. Ikke bekreftet for MSZ-RW.",
            recommendation: "Slå av sikringen til varmepumpen i ett minutt og slå den på igjen. Kommer feilen tilbake: " + callDealer,
            confidence: .low, source: "Mitsubishi generelle kontrollkoder (andre serier)"),
    ]

    /// Operation-indicator blink codes from the MSZ-LN service manual (OBH766H §10-4),
    /// the closest related document available. MSZ-RW's own manual (OBH902C) was not obtained.
    public static let blinkCodes: [Int: ErrorCatalogEntry] = [
        1: blink(1, "Feilkobling eller seriesignal", "Innedelen mottar ikke signal fra utedelen."),
        2: blink(2, "Temperaturføler i innedelen", "Rørføler eller romtemperaturføler er kortsluttet eller brutt."),
        3: blink(3, "Viftemotor i innedelen", "Viftemotoren gir ikke turtallssignal."),
        4: blink(4, "Styrekort i innedelen", "Styrekortet klarer ikke å lese minnet sitt."),
        5: blink(5, "Strømsystem i utedelen", "Kompressoren har stoppet for overstrøm eller oppstartsfeil tre ganger på rad."),
        6: blink(6, "Temperaturfølere i utedelen", "En føler i utedelen er kortsluttet eller brutt."),
        7: blink(7, "Styrekort i utedelen", "Styrekortet i utedelen klarer ikke å lese minnet sitt."),
        14: blink(14, "Annen feil (14 blink eller mer)", "Annen feil oppdaget, blant annet på følere eller ventiler. Ikke start igjen før det er reparert."),
    ]

    private static func blink(_ count: Int, _ title: String, _ explanation: String) -> ErrorCatalogEntry {
        ErrorCatalogEntry(
            code: "blink-\(count)", title: (count == 1 ? "Blinker jevnt: " : "\(count) blink: ") + title, explanation: explanation,
            recommendation: "Slutt å bruke varmepumpen og ring forhandleren (bruksanvisningen sier dette når driftslampen blinker).",
            confidence: .medium, source: "MSZ-LN servicehåndbok OBH766H §10-4 (beslektet modell)")
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
                explanation: "Teksten kommer direkte fra MELCloud." + (known.map { " Mulig tolkning: \($0.explanation)" } ?? ""),
                recommendation: known?.recommendation ?? callDealer,
                confidence: .melcloud, source: "MELCloud")
        }
        if let errorCode, let entry = numeric[errorCode] { return entry }
        return ErrorCatalogEntry(
            code: errorCode.map(String.init) ?? "ukjent",
            title: "Ukjent feilkode" + (errorCode.map { " \($0)" } ?? ""),
            explanation: "Vi har ingen sikker forklaring på denne koden for MSZ-RW. " + caveat,
            recommendation: callDealer, confidence: .unknown, source: "—")
    }
}
