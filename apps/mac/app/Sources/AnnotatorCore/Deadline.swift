import Foundation

/// Releases the caller even when a transport ignores task cancellation. Late replies are discarded.
@MainActor final class Deadline {
    private var continuation: CheckedContinuation<JSON, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(after duration: Duration, operation: @escaping @MainActor () async throws -> JSON) async throws -> JSON {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.operation = Task {
                    do { self.complete(.success(try await operation())) }
                    catch { self.complete(.failure(error)) }
                }
                timer = Task {
                    do { try await Task.sleep(for: duration) } catch { return }
                    DictationLog.write("dictation-request-timeout")
                    self.complete(.failure(BridgeError("Operator did not answer in time. Try again or type your comment.")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.complete(.failure(CancellationError())) }
        }
    }
    private func complete(_ result: Result<JSON, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        operation?.cancel(); operation = nil
        continuation.resume(with: result)
    }
}
