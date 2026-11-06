import Foundation

/// Minimal HTTP abstraction so the backend can be tested with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HeatPumpError.network(L10n.tr("Invalid answer")) }
            return (data, http)
        } catch let error as HeatPumpError {
            throw error
        } catch {
            throw HeatPumpError.network(error.localizedDescription)
        }
    }
}
