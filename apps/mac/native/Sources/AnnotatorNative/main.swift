import AppKit

// Annotator's native helper: accessibility, the overlay, capture and DevTools.
// Rust starts it and talks to it in JSON lines (see Protocol.swift and docs/port.md §1).

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let helper = Helper()

    // Quit when Annotator closes our stdin. Lines go to the main queue in order.
    Thread.detachNewThread {
        while let line = readLine() {
            DispatchQueue.main.async { MainActor.assumeIsolated { helper.receive(line) } }
        }
        exit(0)
    }
    // Quit when Annotator exits.
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parent.setEventHandler { exit(0) }
    parent.resume()

    emit(["type": "online"])
    withExtendedLifetime((helper, parent)) { app.run() }
}
