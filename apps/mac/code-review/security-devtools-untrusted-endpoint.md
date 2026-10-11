# DevTools trusts every listening port and the page's own reply

- Severity: bug
- Area: security
- Location: `Sources/Annotator/DevTools.swift:40`, `Sources/Annotator/DevTools.swift:111`, `Sources/AnnotatorCore/DOMInfo.swift:52`

## What is wrong

For the process under the cursor, `listeningPorts` reads that process's socket table and returns every TCP port in `LISTEN`. `port(for:)` then sends `GET http://127.0.0.1:<port>/json/version` to each one until a body contains `webSocketDebuggerUrl`.

Any local listener that answers that shape is treated as Chrome DevTools. The code then loads `/json/list` and opens `webSocketDebuggerUrl` with no check that the URL is `ws://127.0.0.1` or `ws://localhost`. A target list can point the socket at another host. Annotator connects there and sends `Runtime.evaluate`.

The evaluated program is `DOMInfo.probe`. It runs inside the page, then returns `JSON.stringify(...)`. The page can replace `JSON.stringify`, `elementFromPoint`, or `textContent` before that runs. `DevTools.inspect` decodes the returned string as `DOMInfo` and copies `html`, `selector`, `component`, and `name` onto the target. There is no size cap beyond the one-second socket timeout. On submit, those fields are stored in `pending/` and posted to the annotation server (`Sources/AnnotatorCore/Annotation.swift:152`).

The probe is also not read-only from the page's point of view. It calls into page objects the page controls. A hooked getter runs on every hover over that web area, because `OverlayController.resolve` calls `inspect` for every hit test (`Sources/Annotator/Overlay.swift:157`).

## Why it matters

Hovering an app is enough to make Annotator connect to each of that app's listening ports and, after a match, execute script in the page. A page the user meant only to point at can put cookies, token text, or agent instructions into `html` or `name`. That payload is then what the queue and the Conn session read. A fake debugger URL makes Annotator open an outbound WebSocket the target app did not have to open itself.

Connecting to unrelated local ports is also a behavior change for those services. Some act on the first HTTP request.

## What to change

Take the port from `--remote-debugging-port` in the process arguments, or from one known DevTools port. Do not HTTP-probe every listening socket. Accept a WebSocket URL only when its host is loopback and its port is the port you already checked. Cap the evaluate result (a few dozen kilobytes) and truncate each `DOMInfo` string to a fixed limit before it can reach the annotation record. Treat the result as page content, never as instructions.
