import Foundation

/// Sends one request. Tests replace it with a stub.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum HTTP {
    public static func session(timeout: TimeInterval) -> HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    /// The `error` message of a JSON error body, if any.
    static func errorMessage(_ data: Data) -> String? {
        struct Body: Decodable { var error: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }
}
