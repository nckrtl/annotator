import Foundation

@MainActor public final class Bridge {
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    public var onEvent: ((String, JSON) -> Void)?
    public init() {}
    public func start(executable: URL, environment: [String: String]? = nil) throws {
        let process = Process(), inputPipe = Pipe(), outputPipe = Pipe()
        process.executableURL = executable; process.environment = environment
        process.standardInput = inputPipe; process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process; input = inputPipe.fileHandleForWriting
        let handle = outputPipe.fileHandleForReading
        Task.detached { [weak self] in
            var lines = Lines()
            do {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    for value in try lines.append(chunk) { await self?.receive(value) }
                }
                await self?.failed("Annotator's core stopped. Quit and reopen the app.")
            } catch { await self?.failed(error.localizedDescription) }
        }
    }
    public func request(_ command: String, _ args: JSON = .object([:])) async throws -> JSON {
        guard let input else { throw BridgeError("Annotator's core is not running.") }
        let id = UUID().uuidString
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    var bytes = try JSONEncoder().encode(JSON.object(["id": .string(id), "command": .string(command), "args": args]))
                    bytes.append(10); try input.write(contentsOf: bytes)
                } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(135))
                    self?.pending.removeValue(forKey: id)?.resume(throwing: BridgeError("The core did not answer \(command)."))
                }
            }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
    private func receive(_ value: JSON) {
        if !value["event"].string.isEmpty { onEvent?(value["event"].string, value["payload"]); return }
        guard let continuation = pending.removeValue(forKey: value["id"].string) else { return }
        if value["error"] != .null { continuation.resume(throwing: BridgeError(value["error"].string)) }
        else { continuation.resume(returning: value["result"]) }
    }
    private func failed(_ message: String) {
        input = nil
        let waiting = pending; pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: BridgeError(message)) }
        onEvent?("bridge-error", .string(message))
    }
    public func stop() {
        try? input?.close(); input = nil; process?.terminate(); process = nil
        let waiting = pending; pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: CancellationError()) }
    }
}
