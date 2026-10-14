import Foundation

/// Owned by the helper, independent of the UI host and its HTTP/pipe tasks.
/// If its main actor cannot close the windows, a background backstop ends the helper.
@MainActor public final class OverlayWatchdog {
    private final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        func renew() -> Int { lock.lock(); defer { lock.unlock() }; generation += 1; return generation }
        func matches(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
    }
    private let lease = Lease()
    private var task: Task<Void, Never>?
    public var interval: Duration
    public var expired: () -> Void
    private let forceRelease: @Sendable () -> Void
    public init(interval: Duration = .seconds(15), forceRelease: @escaping @Sendable () -> Void = {}, expired: @escaping () -> Void) {
        self.interval = interval; self.expired = expired; self.forceRelease = forceRelease
    }
    public func activity() {
        stop()
        let generation = lease.renew()
        let lease = self.lease, interval = self.interval, forceRelease = self.forceRelease
        task = Task.detached { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard lease.matches(generation) else { return }
            Task { @MainActor [weak self] in
                guard lease.matches(generation), let self else { return }
                self.stop(); self.expired()
            }
            // No main-actor work in this backstop. WindowServer removes a dead helper's panels.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            if lease.matches(generation) { forceRelease() }
        }
    }
    public func stop() { _ = lease.renew(); task?.cancel(); task = nil }
}
