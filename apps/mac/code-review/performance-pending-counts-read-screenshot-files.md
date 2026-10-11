# Counting pending files reads every screenshot into memory

- Severity: suggestion
- Area: performance
- Location: `Sources/Annotator/Submitter.swift:63`, `Sources/AnnotatorCore/PendingStore.swift:47`

## What is wrong

`countFiles` runs after every submit and every retry step:

```swift
pendingCount = store.pending().count
failedCount = store.failedCount()
```

`pending()` and `records(in:)` read each JSON file with `Data(contentsOf:)`. `failedCount()` uses the same helper, so it loads every refused record, including its screenshot, and then returns `.count`. The bytes are discarded.

`retryPending` also loads every pending body up front, which is necessary to POST them. The count path does not need the bodies.

## Why it matters

One unsent annotation is a multi-megabyte JPEG inside JSON. Opening the menu, finishing a submit, or retrying a later record reads that file again just to show a number. Several failed records make `failedCount()` a large allocation on the main actor, because `Submitter` is `@MainActor` and `countFiles` is synchronous.

## What to change

Count directory entries whose extension is `json`. Read a body only when posting that id. Keep `pendingCount` and `failedCount` as integers updated in `save`, `remove`, and `markFailed`.
