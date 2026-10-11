import AnnotatorCore
import Foundation

/// Posts annotations. Every record is saved locally first and removed only after the server stores it.
@MainActor
final class Submitter {
    let store = PendingStore.standard
    private var retrying = false
    var onChange: (() -> Void)?

    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var lastRetryError: String?

    init() {
        countFiles()
    }

    func submit(_ annotation: Annotation, to client: AnnotationClient?) async -> PostResult {
        let body: Data
        do { body = try annotation.encoded() } catch {
            return .rejected(status: 0, message: "Could not encode the record: \(error)")
        }
        do { try store.save(id: annotation.id, body: body) } catch {
            // Without a local copy a failed POST would lose the comment. Say so, but still try to send.
            lastRetryError = "Could not save a local copy: \(error.localizedDescription)"
        }
        guard let client else {
            countFiles()
            return .unreachable(message: "The server URL in Settings is not valid")
        }
        let result = await client.post(body: body)
        settle(id: annotation.id, result)
        return result
    }

    /// Sends every pending record again, oldest first. Stops at the first retryable failure.
    func retryPending(to client: AnnotationClient?) async {
        guard let client, !retrying else { return }
        retrying = true
        defer { retrying = false }
        for (id, body) in store.pending() {
            let result = await client.post(body: body)
            settle(id: id, result)
            if result.isRetryable {
                lastRetryError = result.message
                break
            }
        }
        countFiles()
    }

    private func settle(id: String, _ result: PostResult) {
        if result.isStored {
            store.remove(id: id)
            lastRetryError = nil
        } else if !result.isRetryable {
            try? store.markFailed(id: id)
        }
        countFiles()
    }

    private func countFiles() {
        pendingCount = store.pendingCount()
        failedCount = store.failedCount()
        onChange?()
    }
}
