import Foundation

/// Sends one request. Tests replace it with a stub.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum HTTP {
    /// Annotation and Conn calls. Ofide uses the longer session so transcription can finish.
    public static func session(timeout: TimeInterval) -> HTTPTransport {
        timeout >= 60 ? long : short
    }

    private static let short = makeSession(timeout: 15)
    private static let long = makeSession(timeout: 125)

    /// A session that cancels a redirect to another scheme, host, or port.
    public static func pinned(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: RedirectStay(), delegateQueue: nil)
    }

    /// The annotation event stream. It stays open, and it does not follow a redirect to another host.
    public static func eventStream() -> URLSession {
        pinned(requestTimeout: 45, resourceTimeout: .infinity)
    }

    private static func makeSession(timeout: TimeInterval) -> HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: RedirectStay(), delegateQueue: nil)
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

/// Refuses a redirect that changes scheme, host, or port, so a token or a screenshot cannot follow it off the original server.
private final class RedirectStay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let from = task.originalRequest?.url, let to = request.url,
            from.scheme?.lowercased() == to.scheme?.lowercased(),
            from.host?.lowercased() == to.host?.lowercased(),
            from.port == to.port
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
