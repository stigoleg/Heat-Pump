import HeatPumpKit
import MapKit
import SwiftUI

/// Settings → Vær: where the MET forecast is for, and an optional contact e-mail for MET.
struct WeatherSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var placeName = ""
    @State private var email = ""
    @State private var loaded = false
    @State private var working = false
    @State private var message: (ok: Bool, text: String)?
    @State private var showCoordinates = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Sted nå") {
                    if let location = model.weatherLocation {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(location.displayName)
                            Text(sourceText(location.source)).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Ikke valgt").foregroundStyle(.secondary)
                    }
                }
                if loaded {
                    LocationPicker(
                        coordinate: chosen, placeName: $placeName, fallback: fallback,
                        fallbackTitle: model.weatherLocation?.source == .demo ? "Demo" : "Fra MELCloud")
                }
                TextField("Navn på stedet (valgfritt)", text: $placeName, prompt: Text("for eksempel Hjemme eller Lillehammer"))
                if chosen.wrappedValue != nil {
                    Button("Bruk posisjonen fra MELCloud i stedet") {
                        latitude = ""
                        longitude = ""
                    }
                }
                DisclosureGroup("Skriv inn koordinater", isExpanded: $showCoordinates) {
                    LabeledContent("Breddegrad") {
                        TextField("Breddegrad", text: $latitude, prompt: Text("for eksempel 60,39"))
                            .labelsHidden().frame(maxWidth: 160).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                    LabeledContent("Lengdegrad") {
                        TextField("Lengdegrad", text: $longitude, prompt: Text("for eksempel 5,32"))
                            .labelsHidden().frame(maxWidth: 160).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                }
            } header: {
                Text("Sted for værvarselet")
            } footer: {
                Text(
                    "Søk etter adressen eller stedet, eller klikk i kartet. Søket går via Apple Kart. Uten valgt sted brukes posisjonen til bygget i MELCloud. Posisjonen rundes av til omtrent én kilometer før den sendes til MET, og Claude ser bare stedsnavnet. Husk å trykke Lagre."
                )
            }

            Section {
                TextField("Kontakt-e-post for MET (valgfritt)", text: $email, prompt: Text("navn@eksempel.no"))
                    .textContentType(.emailAddress)
            } header: {
                Text("Kontakt-e-post for MET")
            } footer: {
                Text(
                    "MET Norway ber alle som henter værdata om å oppgi hvem de er, så de kan ta kontakt hvis noe går galt i stedet for å stenge tilgangen. Appen sender alltid navnet og versjonen sin. Fyller du inn en e-post, sendes den også med i hver forespørsel til MET (høyst én gang i timen). Den brukes ikke til noe annet."
                )
            }

            Section {
                HStack {
                    if let message {
                        Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(message.ok ? Theme.Status.good : Theme.Status.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Lagre") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                }
                if let fetched = model.weatherFetchedAt {
                    LabeledContent("Varsel sist hentet", value: Format.relative(fetched))
                }
                Text(WeatherForecast.attribution).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            let s = await model.loadWeatherSettings()
            latitude = s.latitude.map { Display.format("%.4f", $0) } ?? ""
            longitude = s.longitude.map { Display.format("%.4f", $0) } ?? ""
            placeName = s.placeName ?? ""
            email = s.contactEmail ?? ""
            showCoordinates = s.latitude != nil
            loaded = true
        }
    }

    /// The typed coordinates as a map pin; setting it writes the text fields.
    private var chosen: Binding<CLLocationCoordinate2D?> {
        Binding {
            guard let lat = number(latitude), let lon = number(longitude) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } set: { new in
            latitude = new.map { Display.format("%.4f", $0.latitude) } ?? ""
            longitude = new.map { Display.format("%.4f", $0.longitude) } ?? ""
            message = nil
        }
    }

    /// Where the forecast is for without a chosen place (MELCloud building or demo).
    private var fallback: CLLocationCoordinate2D? {
        guard let location = model.weatherLocation, location.source != .manual else { return nil }
        return CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    private func sourceText(_ source: WeatherLocation.Source) -> String {
        switch source {
        case .manual: "Valgt her"
        case .melcloud: "Fra bygget i MELCloud"
        case .demo: "Demo"
        }
    }

    private func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? nil : Double(trimmed)
    }

    private func save() async {
        let lat = number(latitude)
        let lon = number(longitude)
        if (!latitude.trimmingCharacters(in: .whitespaces).isEmpty && lat == nil)
            || (!longitude.trimmingCharacters(in: .whitespaces).isEmpty && lon == nil)
        {
            message = (false, "Koordinatene må være tall, for eksempel 60,39 og 5,32.")
            return
        }
        working = true
        defer { working = false }
        let settings = WeatherSettings(latitude: lat, longitude: lon, placeName: placeName, contactEmail: email)
        message = await model.saveWeatherSettings(settings)
    }
}
