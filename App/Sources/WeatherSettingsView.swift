import HeatPumpKit
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
                TextField("Navn på stedet (valgfritt)", text: $placeName, prompt: Text("for eksempel Hjemme eller Lillehammer"))
                LabeledContent("Breddegrad (valgfritt)") {
                    TextField("Breddegrad", text: $latitude, prompt: Text("for eksempel 60,39"))
                        .labelsHidden().frame(width: 160).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                }
                LabeledContent("Lengdegrad (valgfritt)") {
                    TextField("Lengdegrad", text: $longitude, prompt: Text("for eksempel 5,32"))
                        .labelsHidden().frame(width: 160).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                }
                Link("Finn koordinatene på yr.no eller i Kart (høyreklikk på kartet)", destination: URL(string: "https://www.yr.no")!)  // constant literal
                    .font(.callout)
            } header: {
                Text("Sted for værvarselet")
            } footer: {
                Text(
                    "Uten egne koordinater bruker appen posisjonen til bygget i MELCloud. Koordinatene rundes av til omtrent én kilometer før de sendes til MET, og vises ikke i appen eller til Claude. Skriv dem med komma eller punktum."
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
            let s = model.weatherSettings
            latitude = s.latitude.map { Norwegian.format("%.4f", $0) } ?? ""
            longitude = s.longitude.map { Norwegian.format("%.4f", $0) } ?? ""
            placeName = s.placeName ?? ""
            email = s.contactEmail ?? ""
            loaded = true
        }
    }

    private func sourceText(_ source: WeatherLocation.Source) -> String {
        switch source {
        case .manual: "Fra koordinatene under"
        case .melcloud: "Fra bygget i MELCloud"
        case .demo: "Demo"
        }
    }

    private func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
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
        if let error = await model.saveWeatherSettings(settings) {
            message = (false, error)
        } else {
            message = (true, "Lagret.")
        }
    }
}
