import Testing
import Foundation
@testable import AnnotatorNativeCore

@Suite(.serialized) struct OverlayWatchdogTests {
@MainActor @Test func silentOverlayReleasesWithoutHostResponse() async throws {
    var captured = true
    let watchdog = OverlayWatchdog(interval: .milliseconds(20)) { captured = false }
    watchdog.activity()
    // Allow executor scheduling under load, while bounding failure to release.
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(1)
    while captured && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!captured)
    watchdog.stop()
}

@MainActor @Test func overlayActivityRenewsAndClosingDisarms() async throws {
    var releases = 0
    let watchdog = OverlayWatchdog(interval: .milliseconds(20)) { releases += 1 }
    watchdog.activity()
    // Renew before yielding: scheduler delays cannot expire the original lease first.
    watchdog.interval = .seconds(60)
    watchdog.activity()
    try await Task.sleep(for: .milliseconds(100))
    #expect(releases == 0)
    watchdog.interval = .milliseconds(20)
    watchdog.activity()
    watchdog.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(releases == 0)
}

@MainActor @Test func blockedMainActorUsesBackgroundBackstop() {
    // Only this test deliberately blocks the actor; the watchdog must not depend on it.
    final class Signal: @unchecked Sendable {
        let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    let signal = Signal()
    let watchdog = OverlayWatchdog(interval: .milliseconds(20), forceRelease: { signal.set() }) {}
    watchdog.activity()
    Thread.sleep(forTimeInterval: 1.2)
    #expect(signal.fired)
    watchdog.stop()
}

}
