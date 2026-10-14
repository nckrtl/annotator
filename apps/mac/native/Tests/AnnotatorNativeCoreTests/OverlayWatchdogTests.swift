import Testing
import Foundation
@testable import AnnotatorNativeCore

@Suite(.serialized) struct OverlayWatchdogTests {
@MainActor @Test func silentOverlayReleasesWithoutHostResponse() async throws {
    var captured = true
    let watchdog = OverlayWatchdog(interval: .milliseconds(20)) { captured = false }
    watchdog.activity()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!captured)
}

@MainActor @Test func overlayActivityRenewsAndClosingDisarms() async throws {
    var releases = 0
    let watchdog = OverlayWatchdog(interval: .milliseconds(60)) { releases += 1 }
    watchdog.activity()
    try await Task.sleep(for: .milliseconds(30))
    watchdog.activity()
    try await Task.sleep(for: .milliseconds(40))
    #expect(releases == 0)
    watchdog.stop()
    try await Task.sleep(for: .milliseconds(70))
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
