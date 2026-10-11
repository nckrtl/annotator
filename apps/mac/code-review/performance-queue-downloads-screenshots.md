# The live queue downloads and keeps every screenshot

- Severity: bug
- Area: performance
- Location: `Sources/Annotator/QueueMonitor.swift:70`, `Sources/AnnotatorCore/AnnotationClient.swift:68`, `Sources/Annotator/AnnotationDetail.swift:161`

## What is wrong

`QueueItem` decodes `screenshot` as a `String?`. `AnnotationClient.queue()` decodes the entire `data` array into those structs. `QueueMonitor.listen` then does this:

```swift
guard await refresh(client) else { return }
setConnection(.live)
for try await line in bytes.lines {
    if Task.isCancelled { return }
    if line.hasPrefix("data:") { await refresh(client) }
}
```

Every server-sent `data:` line throws away the event body and GETs the whole collection again. The fallback poll does the same GET every 3 seconds. The agent prompt already warns that screenshots are large and tells agents to `del(.screenshot)` (`Sources/AnnotatorCore/Projects.swift:156`). The menu bar app does not.

The decoded strings stay in `summary` for the life of the monitor. The menu draws at most 25 open rows and does not show images. Each open detail window calls `AnnotationDetailView.image` from `body`, which base64-decodes the data URL and builds an `NSImage` on the main actor. Replacing `summary` invalidates that body, so every event decodes the JPEG again even when that one image did not change.

A wrong server still returns `false` from `refresh` and the poll loop continues every 3 seconds (`Sources/Annotator/QueueMonitor.swift:63`).

## Why it matters

A few dozen annotations at a few hundred kilobytes of JPEG each are tens of megabytes of JSON per event. Parsing that, holding every data URL, and decoding images on the main thread will hitch the menu bar app. The event stream exists so the client can avoid this poll. Using it to trigger a full download removes that benefit. Heartbeats or bulk updates make it worse.

## What to change

Decode the list without `screenshot`. Load one screenshot when a detail window opens, from `GET` of that id if the server supports it, or from a field you request only then. Apply SSE payloads when they contain the changed record. Coalesce bursts into one refresh. Stop polling after `notAnnotationServer` until the URL changes. Cache the `NSImage` by id and revision so the detail view does not decode on every refresh.
