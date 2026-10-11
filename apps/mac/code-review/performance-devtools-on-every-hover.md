# Every hover over web content opens DevTools and runs JavaScript

- Severity: bug
- Area: performance
- Location: `Sources/Annotator/Overlay.swift:157`, `Sources/Annotator/DevTools.swift:20`, `Sources/Annotator/DevTools.swift:46`

## What is wrong

`scheduleHitTest` aims for 30 tests a second and runs one at a time. Each test calls `resolve`, which always calls `devTools.inspect` after the accessibility read.

`inspect` does all of this when the pointer is inside a web area:

1. Find a DevTools port. The first time it sees a pid, it connects to every listening port of that process. Each attempt uses a session whose request timeout is 1 second (`Sources/Annotator/DevTools.swift:13`). Ports are tried one after another. An app with ten non-DevTools listeners costs up to ten seconds before the hover returns. A miss is cached for 5 seconds. A hit is cached until a later request fails.
2. Fetch `/json/list` unless the page list is younger than 3 seconds.
3. Open a new WebSocket and evaluate `DOMInfo.probeFunction`, which is about 180 lines of DOM and React walking (`Sources/AnnotatorCore/DOMInfo.swift:62`). The call gives up after 1 second.

The hit-test loop waits for that whole chain. The next mouse position cannot be drawn until it finishes. The WebSocket is created per call on purpose, so calls do not share replies. That also means every move pays for a handshake and a full `Runtime.evaluate`.

## Why it matters

Over a native app the hover path is an accessibility call. Over Chrome, Electron, or anything with a web area, it becomes a debugger session. The highlight lags by the probe time, often tens or hundreds of milliseconds, and by a full second when the page does not answer. The first hover over a process that listens on many ports freezes the overlay for seconds. The page also does a fiber walk on each of those calls.

## What to change

Use accessibility for hover. Run `inspect` once, on mouse-up, for the element the user actually clicked. Cache a negative DevTools result per pid without contacting every port. Read `--remote-debugging-port` from the process arguments instead. When a live probe is required while moving, reuse one socket per page and send only the coordinates, at a much lower rate than 30 Hz.
