# Every queue change spawns a Node status process

- Severity: bug
- Area: performance
- Location: `Sources/Annotator/AppController.swift:102`, `Sources/Annotator/AppController.swift:21`, `Sources/AnnotatorCore/LocalServer.swift:48`

## What is wrong

The queue callback does three things on every summary or connection change:

```swift
queue.onChange = { [weak self] in
    self.updateButton()
    self.refreshServerStatus()
    if let summary = self.queue.summary { self.t3.nudge(summary: summary, projects: self.projects.routes.projects) }
}
```

`refreshServerStatus` spawns Node with `serve.mjs status` unless a previous command is still marked busy. `LocalServer.run` starts a process, polls it every 50 milliseconds, and reads its stdout. The queue callback runs after every successful poll and every SSE-driven refresh. Those refreshes are already frequent. See `performance-queue-downloads-screenshots.md`.

While a status process is running, further callbacks skip the spawn (`serverState.busy`). As soon as it exits, the next event starts another. A busy server keeps a Node process running for the whole session.

The same callback is also tied to the hotkey. `observeSettings` watches `serverURL` and `hotkey` together (`Sources/Annotator/AppController.swift:228`). Changing the shortcut sets `serverState.running = false`, restarts the event stream, and asks for status again.

## Why it matters

Process spawn is orders of magnitude more expensive than a menu-bar redraw. Status does not need to track annotation events. The menu already has a server health line from `QueueMonitor`. Forking Node on that stream competes with the hover path and with InjectionNext during development. A shortcut change also drops the live connection for no server-side reason.

## What to change

Call `run("status")` on launch, after start, stop, and restart, and when the server URL changes. Drive the menu dot from the queue connection the rest of the time. Watch the hotkey in a separate observation so editing it only re-registers the Carbon hotkey.
