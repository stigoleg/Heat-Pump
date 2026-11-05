import MapKit
import SwiftUI

/// Address and place search for the weather location (Apple Maps). Suggestions come while
/// typing; choosing one looks up its coordinate.
@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var failed = false
    private let completer = MKLocalSearchCompleter()

    var query = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                completer.cancel()
                results = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Norway first; places elsewhere still show up.
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 64.5, longitude: 13), span: MKCoordinateSpan(latitudeDelta: 14, longitudeDelta: 22))
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            failed = false
            results = Array(self.completer.results.prefix(6))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            failed = true
            results = []
        }
    }

    /// Coordinate of a chosen suggestion, nil when Apple Maps has none.
    func coordinate(of completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response?.mapItems.first?.location.coordinate
    }

    /// Town or place name at a coordinate (after a map click), nil when unknown.
    static func placeName(at coordinate: CLLocationCoordinate2D) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        else { return nil }
        let item = try? await request.mapItems.first
        return item?.addressRepresentations?.cityName ?? item?.name
    }
}

/// Search field, suggestions and a map where a click places the pin.
struct LocationPicker: View {
    /// The chosen coordinate; nil means "use MELCloud's building location".
    @Binding var coordinate: CLLocationCoordinate2D?
    @Binding var placeName: String
    /// Where the forecast is for when nothing is chosen (MELCloud building or demo).
    var fallback: CLLocationCoordinate2D?
    var fallbackTitle = "Fra MELCloud"

    @State private var search = PlaceSearch()
    @State private var camera: MapCameraPosition = .automatic
    @State private var looking = false
    @State private var missed = false

    private var shown: CLLocationCoordinate2D? { coordinate ?? fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Søk etter adresse eller sted", text: $search.query, prompt: Text("for eksempel Storgata 1, Lillehammer"))
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = search.results.first { choose(first) } }
                if looking { ProgressView().controlSize(.small) }
            }
            .padding(Theme.Space.s)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))

            if !search.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results, id: \.self) { result in
                        Button {
                            choose(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Theme.Space.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if missed || (search.failed && !search.query.isEmpty) {
                Text("Fant ingen treff. Prøv et annet navn, eller klikk i kartet.").font(.caption).foregroundStyle(.secondary)
            }

            MapReader { proxy in
                Map(position: $camera) {
                    if let shown {
                        Marker(coordinate == nil ? fallbackTitle : (placeName.isEmpty ? "Valgt sted" : placeName), coordinate: shown)
                            .tint(coordinate == nil ? .gray : .accentColor)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .onTapGesture(coordinateSpace: .local) { point in
                    guard let tapped = proxy.convert(point, from: .local) else { return }
                    coordinate = tapped
                    Task {
                        if let name = await PlaceSearch.placeName(at: tapped) { placeName = name }
                    }
                }
            }
            .frame(minHeight: 220, idealHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
            Text("Klikk i kartet for å sette eller flytte nålen.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { center(on: shown) }
    }

    private func choose(_ result: MKLocalSearchCompletion) {
        looking = true
        missed = false
        Task {
            defer { looking = false }
            guard let found = await search.coordinate(of: result) else {
                missed = true
                return
            }
            coordinate = found
            placeName = result.title
            search.query = ""
            center(on: found)
        }
    }

    private func center(on point: CLLocationCoordinate2D?) {
        guard let point else { return }
        camera = .region(MKCoordinateRegion(center: point, latitudinalMeters: 8000, longitudinalMeters: 8000))
    }
}
