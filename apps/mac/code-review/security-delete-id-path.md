# Delete puts the server's id straight into the URL path

- Severity: bug
- Area: security
- Location: `Sources/AnnotatorCore/AnnotationClient.swift:185`, `Sources/Annotator/AppController.swift:561`

## What is wrong

`delete(id:)` percent-encodes with `CharacterSet.urlPathAllowed` and appends the result to the annotation base URL. That set still allows `/` and `.`.

Checked with Foundation:

| id from the queue | request URL |
| --- | --- |
| `abc` | `http://127.0.0.1:29703/annotations/abc` |
| `../secret` | `http://127.0.0.1:29703/annotations/../secret` |
| `foo/bar` | `http://127.0.0.1:29703/annotations/foo/bar` |

Clear Open deletes every open id from the last queue response (`Sources/Annotator/AppController.swift:562`). Those ids are whatever the server sent. The app's own records use a UUID. The delete path does not check the server's grammar, `^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$`.

HTTP stacks commonly normalize `/annotations/../secret` to `/secret` on that same origin before the handler runs.

## Why it matters

A queue response can make this app DELETE a path outside `/annotations` on the configured origin. The user gesture is Clear Open, which the menu describes as deleting annotations. The request can be a different resource on that host and port. A mistaken or hostile server, or a proxy in front of it, supplies the id.

## What to change

Before `delete`, accept only ids that match the server grammar. Encode the id with a set that does not allow `/`, `\`, or `.`, or send it in a JSON body if the server allows that. Do the same check anywhere a server id is later used as a path segment.
