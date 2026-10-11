# Hover walks a large accessibility subtree on one serial queue

- Severity: suggestion
- Area: performance
- Location: `Sources/Annotator/AXReader.swift:93`, `Sources/Annotator/AXReader.swift:172`

## What is wrong

Every hover calls `readTarget`. That copies the on-screen window list, then walks up to 64 ancestors. For each ancestor it reads role, subrole, title, description, identifier, value, help, DOM id, and class list. Each read is `AXUIElementCopyAttributeValue`.

When the hit element has no name, `innerText` does a breadth-first walk of up to 60 nodes, and it enqueues up to 20 children per node. Children and values are further accessibility calls. This runs on the single queue `com.nckrtl.annotator.ax`. The overlay waits for it.

The process-wide messaging timeout is 0.25 seconds. That bound is correct. It multiplies. A target that does not answer can burn 0.25 seconds times the number of calls. `innerText` alone can be dozens of calls, so one hover can hold the queue for many seconds. Later hovers, including ones over a healthy app, wait behind it. The click path uses the same queue.

## Why it matters

The 30 Hz cap does not help while one test still occupies the queue. A stuck Electron helper or a paused debugger makes the highlight freeze, and it delays the click that would otherwise fall back to the window frame.

## What to change

On hover, read the hit element's role, title, and frame only. Walk the parent chain and `innerText` on mouse-up, when you are about to freeze the highlight. Cap `innerText` at a handful of calls. If a call returns a timeout, stop the walk and use the window fallback immediately instead of issuing the rest.
