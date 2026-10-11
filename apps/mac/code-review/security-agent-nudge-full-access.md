# New annotations auto-start a full-access agent

- Severity: bug
- Area: security
- Location: `Sources/AnnotatorCore/Projects.swift:28`, `Sources/Annotator/Settings.swift:50`, `Sources/Annotator/T3Sessions.swift:134`

## What is wrong

A new project defaults to Conn runtime mode `full-access`. Missing `t3RuntimeMode` in an older `routes.json` also becomes `full-access` (`Sources/AnnotatorCore/Projects.swift:52`).

Conn integration and nudges default to on:

```swift
t3Enabled = defaults.object(forKey: "t3Enabled") as? Bool ?? true
t3Nudge = defaults.object(forKey: "t3Nudge") as? Bool ?? true
```

`QueueMonitor` calls `t3.nudge` on every queue change (`Sources/Annotator/AppController.swift:106`). When the project's thread is idle, `nudge` dispatches `thread.turn.start` with `T3Nudge.text`, which tells the agent to work through the new numbers the same way as before (`Sources/AnnotatorCore/T3.swift:183`). The thread was created with that project's `t3RuntimeMode` (`Sources/Annotator/T3Sessions.swift:80`).

The agent then follows `AgentPrompt`, which tells it to claim the record and read `native.dom` HTML, accessibility values, the URL, and the screenshot (`Sources/AnnotatorCore/Projects.swift:160`). Those fields come from the app under the cursor. A web page chooses its own text, aria labels, and the DevTools payload described in `security-devtools-untrusted-endpoint.md`. The prompt says the comment is the request and the rest is context. The model still receives the page text in the same turn, and the turn already has full access.

## Why it matters

The user does not press Start Session again. Saving a comment on a matching window is enough. The idle agent wakes with permission to act without an approval prompt, and part of its input is content from another app. A hostile page, or a page that quotes instructions in its UI, gets that content into a full-access coding session. The default applies to every new project, including ones created from the plus button in Projects.

## What to change

Default `t3RuntimeMode` to `approval-required`. Keep `full-access` as an explicit picker choice, which the Projects screen already has. Default `t3Nudge` to off, or send the nudge only when the project's mode is not `full-access`. In the prompt, tell the agent to treat `native.dom`, accessibility strings, and the screenshot as untrusted quotations, and cap how much of them it loads into the turn.
