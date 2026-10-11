# Capture and Ofide URLs are not pinned to the host the user sees

- Severity: bug
- Area: security
- Location: `Sources/Annotator/Settings.swift:70`, `Sources/AnnotatorCore/OfideClient.swift:118`, `Sources/AnnotatorCore/HTTP.swift:7`

## What is wrong

`Settings.validURL` accepts any `http` or `https` URL that has a host. It does not reject userinfo.

```swift
static func validURL(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
        ["http", "https"].contains(url.scheme), url.host() != nil
    else { return nil }
    return url
}
```

That helper is the gate for the annotation server and for Ofide. A URL that looks local is not local when it contains userinfo. Foundation parses it like this:

| Typed URL | Host that is actually used | Userinfo |
| --- | --- | --- |
| `http://127.0.0.1:29703/annotations` | `127.0.0.1:29703` | none |
| `http://127.0.0.1:29703@attacker.example/annotations` | `attacker.example` | user `127.0.0.1`, password `29703` |

The annotation POST, the queue GET, and the event stream then go to `attacker.example`. The body includes the screenshot, the comment, accessibility text, and DOM HTML.

Ofide is worse. `ofideClient()` reads the Local API token from `control.json` and `OfideClient.send` sets `X-Ofide-Token` on every request, including `status`, `dictate/start`, and `dictate-stop`. The same userinfo URL sends that token off the machine. The default session also follows redirects. A cross-host redirect drops `Authorization`. It keeps a custom header such as `X-Ofide-Token`, and a 307 or 308 keeps the body.

`LocalServer` already refuses this shape: loopback host only, no user, no password, no query, no fragment (`Sources/AnnotatorCore/LocalServer.swift:8`). The data path does not use that check. The Conn save button does (`Sources/Annotator/SettingsView.swift:88`). Ofide and the annotation URL do not.

`HTTP.session` builds a stock ephemeral `URLSession`. Nothing there limits hosts, disables redirects, or strips the token header.

## Why it matters

One pasted URL sends screen captures to another origin. The same paste sends the Ofide Local API token, which can start and stop dictation and trigger a paste into the focused field. The menu can still show a URL that begins with `127.0.0.1`.

Cleartext `http` to a non-loopback host has the same leak without userinfo. The field accepts that too.

## What to change

Parse the URL once and show the host you will actually use. Reject userinfo, a query, and a fragment for every endpoint. Allow Ofide only on `127.0.0.1` or `localhost`. For the annotation server, require an explicit confirm when the host is not loopback, and prefer `https` there. On the session, refuse cross-host redirects for any request that carries `X-Ofide-Token` or a screenshot body.
