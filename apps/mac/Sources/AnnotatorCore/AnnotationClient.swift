import Foundation

/// The outcome of posting one annotation.
public enum PostResult: Sendable, Equatable {
    /// 201: the server stored a new record.
    case created(number: Int?)
    /// 200: the server already had this id. A retry landed.
    case existing(number: Int?)
    /// 410: the record was deleted on the server. Do not resend.
    case deleted
    /// 413: over the server's size limit. Do not resend.
    case tooLarge
    /// Another 4xx. The server will not accept this record. Do not resend.
    case rejected(status: Int, message: String)
    /// 5xx. Try again later.
    case serverError(status: Int, message: String)
    /// No answer, or an answer from something that is not an annotation server. Try again later.
    case unreachable(message: String)

    public var isStored: Bool {
        switch self {
        case .created, .existing: true
        default: false
        }
    }

    /// Whether a later retry can succeed.
    public var isRetryable: Bool {
        switch self {
        case .serverError, .unreachable: true
        default: false
        }
    }

    public var message: String {
        switch self {
        case .created(let number): "Sent" + (number.map { " as #\($0)" } ?? "") + "."
        case .existing(let number): "Already on the server" + (number.map { " as #\($0)" } ?? "") + "."
        case .deleted: "The server says this annotation was deleted. It was not sent again."
        case .tooLarge: "The server rejected the annotation: it is over 10 MiB."
        case .rejected(let status, let message): "The server rejected the annotation (\(status)): \(message)"
        case .serverError(let status, let message): "Server error (\(status)): \(message). Saved locally; it will retry."
        case .unreachable(let message): "Server unreachable: \(message). Saved locally; it will retry."
        }
    }
}

/// A record as the server returns it. Every field beyond `id`, `status` and `comment` is optional,
/// because the web annotator and agents also write records.
public struct QueueItem: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var number: Int?
    public var status: String
    public var comment: String
    public var createdAt: Int64?
    public var claimedAt: Int64?
    public var completedAt: Int64?
    /// The agent's note when it finished or handed the item back.
    public var summary: String?
    /// True when an agent handed the item back with a question in `summary`.
    public var question: Bool?
    public var element: String?
    public var elementPath: String?
    public var url: String?
    public var pathname: String?
    public var boundingBox: Annotation.Box?
    public var screenSize: String?
    public var screenshot: String?
    /// Set by the web annotator, and by this app when it read the DOM over DevTools.
    public var component: String?
    public var react: String?
    public var native: Native?

    public struct Native: Decodable, Sendable, Equatable {
        public var app: Annotation.App?
        public var window: Window?
        public var mode: String?
        public var webUrl: String?
        public var dom: Annotation.DOM?
        public var project: String?

        public struct Window: Decodable, Sendable, Equatable {
            public var title: String?
            public var id: UInt32?
        }
    }

    public var isOpen: Bool { status == "todo" || status == "in_progress" }
    public var isInProgress: Bool { status == "in_progress" }
    public var needsAnswer: Bool { status == "todo" && question == true }

    public init(id: String, number: Int?, status: String, comment: String) {
        self.id = id
        self.number = number
        self.status = status
        self.comment = comment
    }
}

public struct QueueSummary: Sendable, Equatable {
    public var todo = 0
    public var inProgress = 0
    public var done = 0
    /// Todo and in-progress items, oldest first, so the next one an agent claims is at the top.
    public var open: [QueueItem] = []
    /// Everything else, newest first.
    public var finished: [QueueItem] = []

    public init(items: [QueueItem]) {
        for item in items {
            switch item.status {
            case "todo": todo += 1
            case "in_progress": inProgress += 1
            default: done += 1
            }
        }
        let byNumber = items.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        open = byNumber.filter(\.isOpen)
        finished = byNumber.filter { !$0.isOpen }.reversed()
    }

    public func item(id: String) -> QueueItem? {
        open.first { $0.id == id } ?? finished.first { $0.id == id }
    }
}

public enum QueueError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case notAnnotationServer
    case badStatus(Int)

    public var description: String {
        switch self {
        case .unreachable(let message): "Server unreachable: \(message)"
        case .notAnnotationServer: "This URL is not an @nckrtl/annotator server."
        case .badStatus(let status): "The server answered \(status)."
        }
    }
}

/// Talks to an `@nckrtl/annotator` server at `base`, for example `http://127.0.0.1:29703/annotations`.
public struct AnnotationClient: Sendable {
    public var base: URL
    var transport: HTTPTransport

    public init(base: URL, transport: @escaping HTTPTransport = HTTP.session(timeout: 15)) {
        self.base = base
        self.transport = transport
    }

    public var eventsURL: URL { base.appending(path: "events") }

    public func post(_ annotation: Annotation) async -> PostResult {
        let body: Data
        do { body = try annotation.encoded() } catch {
            return .rejected(status: 0, message: "Could not encode the record: \(error)")
        }
        return await post(body: body)
    }

    /// Posts an encoded record, as stored by `PendingStore`.
    public func post(body: Data) async -> PostResult {
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) } catch {
            return .unreachable(message: error.localizedDescription)
        }
        let message = HTTP.errorMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        switch response.statusCode {
        case 201: return .created(number: Self.number(in: data))
        case 200: return .existing(number: Self.number(in: data))
        case 410: return .deleted
        case 413: return .tooLarge
        case 400..<500: return .rejected(status: response.statusCode, message: message)
        case 500..<600: return .serverError(status: response.statusCode, message: message)
        default: return .unreachable(message: "Unexpected status \(response.statusCode)")
        }
    }

    /// Deletes one record. True when the server removed it or never had it.
    public func delete(id: String) async -> Bool {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return false }
        var request = URLRequest(url: base.appending(path: encoded, directoryHint: .notDirectory))
        request.httpMethod = "DELETE"
        guard let (_, response) = try? await transport(request) else { return false }
        return response.statusCode == 200 || response.statusCode == 404
    }

    public func queue() async throws(QueueError) -> QueueSummary {
        struct Body: Decodable {
            struct Meta: Decodable { var service: String? }
            var data: [QueueItem]
            var meta: Meta?
        }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(URLRequest(url: base)) } catch {
            throw .unreachable(error.localizedDescription)
        }
        guard response.statusCode == 200 else { throw .badStatus(response.statusCode) }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
            body.meta?.service == "@nckrtl/annotator"
        else { throw .notAnnotationServer }
        return QueueSummary(items: body.data)
    }

    static func number(in data: Data) -> Int? {
        struct Body: Decodable {
            struct Record: Decodable { var number: Int? }
            var data: Record
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.data.number
    }
}
