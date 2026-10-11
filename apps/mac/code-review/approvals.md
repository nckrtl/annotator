# What I would approve

These parts are sound. They are not findings.

## Permissions and signing

Release entitlements are empty. The app is not sandboxed, which accessibility of other apps requires, and the hardened runtime stays on. Library validation is disabled only in `Resources/AnnotatorDev.entitlements`, and `scripts/bundle.sh` uses that file only for the debug build.

The global shortcut uses Carbon `RegisterEventHotKey` (`Sources/Annotator/HotKeyCenter.swift`). It does not install a `CGEventTap`, so the app does not need Input Monitoring. A shortcut with no Control, Option, or Command is rejected (`Sources/AnnotatorCore/Hotkey.swift`).

Relaunch passes the bundle path as `$0` to `/bin/sh`, so the path is not interpolated into the script (`Sources/Annotator/Permissions.swift`).

## Accessibility timeout

`AXUIElementSetMessagingTimeout` is called on the system-wide element (`Sources/Annotator/AXReader.swift`). Apple's header says that sets the timeout for the whole process. A hung target is bounded at about 0.25 seconds per call. Hit tests run on one background queue, at most one at a time, at about 30 Hz (`Sources/Annotator/Overlay.swift`).

## Local server control

`LocalServer` starts and stops a process only for `http` URLs whose host is `127.0.0.1` or `localhost`, whose path is `/annotations`, and which have no user, password, query, or fragment (`Sources/AnnotatorCore/LocalServer.swift`). The Node program receives argv. It does not go through a shell. The command is capped at 15 seconds.

`scripts/dev.sh` signals a process only when its argument vector equals this checkout's binary.

## Annotation protocol

A record is written under `pending/` before the POST. The client treats 201 and 200 as stored, and it does not retry 410, 413, or other 4xx (`Sources/AnnotatorCore/AnnotationClient.swift`, `Sources/Annotator/Submitter.swift`). Ids the app creates are lowercase UUIDs, which match the server's id grammar.

JPEG output is shrunk until the data URL fits under the 10 MiB request limit, with 256 KiB held back for the rest of the record (`Sources/AnnotatorCore/ScreenshotEncoder.swift`). Capture excludes this app's own windows.

Accessibility values are truncated to 200 characters when the snapshot is built (`Sources/AnnotatorCore/AXSnapshot.swift`).

## Conn token storage

The Conn bearer token is stored in the login Keychain, keyed by the endpoint string. It is not written to UserDefaults. The Save Connection button rejects userinfo, a query, a fragment, and a non-empty path (`Sources/Annotator/SettingsView.swift`, `Sources/Annotator/T3Sessions.swift`). Reading the token for a different endpoint does not return the token saved for `http://127.0.0.1:3780`, except for that one explicit local migration.
