import Foundation

public enum OfideResult: Sendable, Equatable {
    case ok
    /// 409: no active dictation, or focus changed.
    case noDictation
    /// 422: Ofide heard only silence.
    case silence
    case failed(String)
    case notRunning
    /// 401: missing or wrong Local API token.
    case unauthorized

    public var message: String? {
        switch self {
        case .ok: nil
        case .noDictation: "No active dictation, or focus changed."
        case .silence: "Ofide heard only silence."
        case .failed(let message): "Ofide failed: \(message)"
        case .notRunning: "Ofide is not running."
        case .unauthorized: "Ofide rejected the Local API token. Check Ofide → Settings → Local API."
        }
    }
}

/// Reads Ofide's Local API token from the app's `control.json`.
public enum OfideToken {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .missing(let path): "No Ofide Local API token at \(path). Turn on Local API in Ofide → Settings."
            case .unreadable(let path): "Could not read the Ofide Local API token in \(path)."
            }
        }
    }

    /// `bundleId` is `com.nckrtl.ofide` or `com.nckrtl.ofide.dev`.
    public static func file(bundleId: String, home: URL = .homeDirectory) -> URL {
        home.appending(path: "Library/Application Support/\(bundleId)/control.json")
    }

    public static func read(_ file: URL) throws(Failure) -> String {
        guard let data = FileManager.default.contents(atPath: file.path) else { throw .missing(file.path) }
        struct Control: Decodable { var token: String? }
        guard let token = (try? JSONDecoder().decode(Control.self, from: data))?.token, !token.isEmpty
        else { throw .unreadable(file.path) }
        return token
    }
}

/// Ofide's local dictation API. See `~/apps/ofide/README.md`.
public struct OfideClient: Sendable {
    public struct State: Decodable, Sendable {
        public var status: String
        public var cancelledAt: Double?
    }
    public var base: URL
    /// Ofide's Local API token, sent as `X-Ofide-Token`.
    public var token: String
    var transport: HTTPTransport

    /// `/dictate-stop` waits for transcription and paste, up to 120 seconds.
    public init(base: URL, token: String, transport: @escaping HTTPTransport = HTTP.session(timeout: 125)) {
        self.base = base
        self.token = token
        self.transport = transport
    }

    /// `.ok` when Ofide answers and accepts the token.
    public func status() async -> OfideResult {
        var request = URLRequest(url: base.appending(path: "status"))
        request.timeoutInterval = 2
        return await send(request)
    }

    /// Starts recording. Safe to repeat. Ofide pastes into the focused field however the recording ends:
    /// `stop()`, its own hotkey, or its pause detection.
    public func start() async -> OfideResult {
        await send("dictate/start")
    }

    /// Ofide's state: `loading`, `arming`, `recording`, `transcribing`, `ready`, or an error.
    /// Nil when Ofide does not answer.
    public func state() async -> String? {
        await snapshot()?.status
    }

    public func snapshot() async -> State? {
        var request = URLRequest(url: base.appending(path: "status"))
        request.timeoutInterval = 2
        request.setValue(token, forHTTPHeaderField: "X-Ofide-Token")
        guard let (data, response) = try? await transport(request), response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    /// Cancels without requesting transcription or paste.
    public func cancel() async -> OfideResult {
        var request = URLRequest(url: base.appending(path: "dictate/cancel"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        return await send(request)
    }

    /// Stops, transcribes and pastes into the focused field. Returns after the paste.
    public func stop() async -> OfideResult {
        await send("dictate-stop")
    }

    func send(_ path: String) async -> OfideResult {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        return await send(request)
    }

    func send(_ request: URLRequest) async -> OfideResult {
        var request = request
        request.setValue(token, forHTTPHeaderField: "X-Ofide-Token")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) } catch { return .notRunning }
        switch response.statusCode {
        case 200, 202: return .ok
        case 409: return .noDictation
        case 422: return .silence
        case 401: return .unauthorized
        default:
            let detail = HTTP.errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            return .failed("\(response.statusCode) \(detail)")
        }
    }
}
