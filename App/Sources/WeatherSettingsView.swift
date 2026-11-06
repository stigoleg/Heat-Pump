import HeatPumpKit
import MapKit
import SwiftUI

/// Settings → Weather: where the MET forecast is for, and an optional contact e-mail for MET.
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
                LabeledContent("Current place") {
                    if let location = model.weatherLocation {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(location.displayName(serviceName: model.serviceName))
                            Text(sourceText(location.source)).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not chosen").foregroundStyle(.secondary)
                    }
                }
                if loaded {
                    LocationPicker(
                        coordinate: chosen, placeName: $placeName, fallback: fallback,
                        fallbackTitle: model.weatherLocation?.source == .demo ? String(localized: "Demo") : String(localized: "From \(model.serviceName)"))
                }
                TextField("Name of the place (optional)", text: $placeName, prompt: Text("for example Home or Lillehammer"))
                if chosen.wrappedValue != nil {
                    Button("Use the Location from \(model.serviceName) Instead") {
                        latitude = ""
                        longitude = ""
                    }
                }
                DisclosureGroup("Enter coordinates", isExpanded: $showCoordinates) {
                    LabeledContent("Latitude") {
                        TextField("Latitude", text: $latitude, prompt: Text("for example 60.39"))
                            .labelsHidden().frame(maxWidth: 160).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                    LabeledContent("Longitude") {
                        TextField("Longitude", text: $longitude, prompt: Text("for example 5.32"))
                            .labelsHidden().frame(maxWidth: 160).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                }
            } header: {
                Text("Place for the weather forecast")
            } footer: {
                Text(
                    "Search for the address or place, or click in the map. The search goes through Apple Maps. Without a chosen place, the location of the building in \(model.serviceName) is used. The location is rounded to about one kilometer before it is sent to MET, and Claude only sees the place name. Remember to click Save."
                )
            }

            Section {
                TextField("Contact email for MET (optional)", text: $email, prompt: Text("name@example.com"))
                    .textContentType(.emailAddress)
            } header: {
                Text("Contact email for MET")
            } footer: {
                Text(
                    "MET Norway asks everyone who fetches weather data to say who they are, so they can get in touch if something goes wrong instead of blocking access. The app always sends its name and version. If you enter an email, it is also sent with every request to MET (at most once an hour). It is not used for anything else."
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
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                }
                if let fetched = model.weatherFetchedAt {
                    LabeledContent("Forecast last fetched", value: Format.relative(fetched))
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
        case .manual: String(localized: "Chosen here")
        case .service: String(localized: "From the building in \(model.serviceName)")
        case .demo: String(localized: "Demo")
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
            message = (false, String(localized: "The coordinates must be numbers, for example 60.39 and 5.32."))
            return
        }
        working = true
        defer { working = false }
        let settings = WeatherSettings(latitude: lat, longitude: lon, placeName: placeName, contactEmail: email)
        message = await model.saveWeatherSettings(settings)
    }
}
