# Each client builds a new URLSession and never invalidates it

- Severity: suggestion
- Area: performance
- Location: `Sources/AnnotatorCore/HTTP.swift:7`, `Sources/Annotator/AppController.swift:95`, `Sources/AnnotatorCore/OfideClient.swift:66`

## What is wrong

`HTTP.session` creates a new ephemeral `URLSession` and captures it in the transport closure. Nothing calls `finishTasksAndInvalidate` or `invalidateAndCancel`.

`AppController.client` is a computed property. Every read builds an `AnnotationClient`, which builds another session with a 15-second resource timeout:

```swift
private var client: AnnotationClient? { settings.server.map { AnnotationClient(base: $0) } }
```

That property is read for submit, retry, clear, and each `queue.start`. `ofideClient()` does the same on the dictation path, with a 125-second resource timeout (`Sources/AnnotatorCore/OfideClient.swift:66`). `T3Client` does it again for each authorized call. Per-request `timeoutInterval` values are set later, so the session-level timeout is mostly a reason to have built a session.

`QueueMonitor` is the exception. It keeps one session for the event stream.

## Why it matters

A `URLSession` owns a delegate queue, a connection pool, and cache state until it is invalidated. Releasing the client does not reliably tear that down. A menu-bar app that posts annotations and polls Ofide for hours accumulates sessions. The 125-second Ofide session is the expensive one. It exists so one `dictate-stop` can wait for transcription. A single shared session with a long timeout on that one request does the same job.

## What to change

Keep one ephemeral session on `AppController` for annotation traffic, one for Ofide, and one for Conn. Set `timeoutInterval` on the `URLRequest`. Invalidate each session in `applicationWillTerminate`. Stop building sessions inside `HTTP.session` on the call path.
