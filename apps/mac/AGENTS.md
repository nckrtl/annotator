# Annotator for macOS

A native macOS menu bar app that lets the user annotate anything on screen.
They press a hotkey, hover, and see the UI element under the cursor
highlighted. They click it, type or dictate a comment, and submit. The app
captures a screenshot and the element's accessibility details, then posts the
annotation to the same queue the web annotator (`@nckrtl/annotator`) uses.
Coding agents claim the queue, make the change, and mark each item done.

It is the system-wide version of the web annotator. It works on native apps,
Electron apps, browsers and anything else on screen.

Nothing is built yet. This file is the brief. Read it all before you start.

## Status and scope

- Repo: `~/apps/annotator-mac` (this folder). Git is initialized; there is no
  remote yet. Ask the user before you create one.
- The web package lives at `~/apps/annotator`. Do not change it from here.
  This app only talks to its server over HTTP.
- Build phase 1 first (below). Stop after it, show the user, and wait for
  feedback before phase 2.

## Users and principles

- The user is the only user. Optimize for their workflow, not for
  distribution: no App Store, no notarization, no auto-update.
- Loud failures. If a permission is missing, the server is down, or a capture
  fails, say so in the UI. Never fail silently or fall back without telling.
- Deterministic and simple. No speculative abstractions, no legacy or
  compatibility code. Keep the code small enough to read in one sitting.
- Independent. It must not depend on T3 Code, Orbit or any other app. It only
  needs an annotation server URL.
- Write text (UI, comments, docs) in plain, brief English: short sentences,
  active voice.

## How it works

1. **Toggle.** A global hotkey (default ⌃⌥A, configurable) or the menu bar
   item turns annotate mode on and off. Esc turns it off.
2. **Overlay.** In annotate mode, one borderless transparent `NSPanel` per
   screen covers the display above normal windows. It takes mouse events, so
   clicks do not reach the app underneath. It draws a highlight rectangle
   around the hovered element and a small label: app name, role and title.
3. **Hit test.** On mouse move, find the element under the cursor:
   - Use `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` to
     get the topmost on-screen window at the point, skipping this app's own
     windows (match `kCGWindowOwnerPID` against our pid) and windows at
     layer > 0 that are not app content (menu bar, Dock, overlays).
   - Create `AXUIElementCreateApplication(pid)` for that window's owner and
     call `AXUIElementCopyElementAtPosition(appElement, x, y)`. Do not use the
     system-wide element: our own overlay is on top and would be hit.
   - Read `kAXRoleAttribute`, `kAXSubroleAttribute`,
     `kAXRoleDescriptionAttribute`, `kAXTitleAttribute`,
     `kAXDescriptionAttribute`, `kAXIdentifierAttribute`,
     `kAXValueAttribute` (truncate), `kAXHelpAttribute`, `kAXPositionAttribute`
     and `kAXSizeAttribute`. Walk `kAXParentAttribute` up to the window to
     build the element path. For web content, also read `AXURL` and
     `AXDocument` from the web area.
   - Electron apps expose an empty tree until asked. When the owner is an
     Electron app, set `AXManualAccessibility` to true on the app element once
     per pid. Do not set `AXEnhancedUserInterface` (it breaks window
     animations in some apps).
   - If no element comes back, or the element has no usable frame, fall back to
     the window frame. Label it as a window-level annotation; do not hide that.
   - Throttle hit tests (about 30 per second) and run them off the main
     thread. Accessibility calls can block on a hung app; use
     `AXUIElementSetMessagingTimeout` (about 0.25s).
4. **Region mode.** Hold ⌥ while dragging to annotate a free rectangle instead
   of an element. Use it for canvas apps, games and other UI without
   accessibility data.
5. **Comment.** On click, freeze the highlight and show a comment panel next
   to the element. It must be able to become key, because Ofide's dictation
   pastes into the focused field. ⌘↩ submits, Esc cancels. Optional dictation
   button: see Dictation.
6. **Capture.** Use ScreenCaptureKit, with `SCScreenshotManager` and an
   `SCContentFilter` for the display. Capture the element frame plus a 24pt
   margin, and also the full window in phase 2. Exclude this app's own windows
   from the filter, so the overlay and panel are not in the image. Encode as
   JPEG (quality about 0.8) and downscale if needed to keep the request under
   the server's 10 MiB limit. Capture right before you show the comment panel,
   so the image shows what the user clicked on.
7. **Submit.** POST the record (below) to the server. Show success or the
   server's error in the panel. Keep a local copy until the POST succeeds, so a
   down server does not lose the comment.
8. **Queue.** The menu bar menu shows open, in-progress and done counts, the
   latest items with their number and comment, and a link to open the server
   URL. Subscribe to `GET <base>/events` (server-sent events) for live
   updates; fall back to polling `GET <base>` every 3s if the stream drops,
   and show "server unreachable" after three failed polls.

## Annotation server contract

Default base URL: `http://127.0.0.1:29703/annotations`, configurable in
settings. Run a server for development with:

```bash
npx @nckrtl/annotator serve --port 29703 --store ~/.annotator/annotations
```

(The user also runs one from `~/apps/conn/apps/web` for Conn (T3 Code fork) work:
`node node_modules/@nckrtl/annotator/bin/serve.mjs serve --port 29703 --store ~/.t3/dev/annotations`.
Do not stop a server you did not start.)

Endpoints, all JSON with `Content-Type: application/json`:

| Request | Meaning |
| --- | --- |
| `GET <base>` | `{data: Annotation[], meta: {service: "@nckrtl/annotator", lastNumber, ...}}`. Check `meta.service` to confirm the server. |
| `POST <base>` | Create. Body must have `id` (client-generated, see below) and a non-empty `comment`. The server adds `number`, `status: "todo"`, `createdAt`, `revision`. Re-posting the same `id` returns the existing record (200), so retries are safe. `410` means the record was deleted; do not resend. `413` means over 10 MiB. |
| `GET <base>/events` | Server-sent events on any change. |
| `POST <base>/claim` | Agents claim work. Not used by this app. |
| `POST <base>/complete`, `/release` | Agents finish or hand back work. Not used by this app. |
| `DELETE <base>/<id>` | Remove one record. |
| `GET <base>/skill` | The agent instructions for draining the queue. |

The server accepts ids matching `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,199}$`
(`validId` in `~/apps/annotator/bin/store.mjs`). Use a lowercase UUID string.

Record this app posts. The first group are the fields the web annotator and
existing agents already read; keep their meaning. The `native` object is new.

```json
{
  "id": "6f1c…-uuid",
  "timestamp": 1791400000000,
  "comment": "The sidebar title is clipped",
  "element": "AXStaticText \"Inbox\"",
  "elementPath": "AXWindow \"Mail\" > AXSplitGroup > AXOutline > AXRow > AXStaticText \"Inbox\"",
  "url": "app://com.apple.mail",
  "pathname": "Mail — Inbox",
  "boundingBox": {"x": 120, "y": 340, "width": 180, "height": 22},
  "screenSize": "3024px, 1964px",
  "screenshot": "data:image/jpeg;base64,…",
  "native": {
    "app": {"name": "Mail", "bundleId": "com.apple.mail", "pid": 812},
    "window": {"title": "Inbox", "id": 4711, "frame": {"x": 0, "y": 38, "width": 1512, "height": 944}},
    "ax": {
      "role": "AXStaticText", "subrole": null, "roleDescription": "text",
      "title": "Inbox", "description": null, "identifier": null, "value": null,
      "path": ["AXWindow \"Mail\"", "AXSplitGroup", "AXOutline", "AXRow", "AXStaticText \"Inbox\""]
    },
    "webUrl": null,
    "mode": "element",
    "project": null
  }
}
```

- `boundingBox` is in global screen points with a top-left origin (the
  accessibility and CoreGraphics convention). AppKit uses a bottom-left
  origin per screen; convert in one tested helper, and use it everywhere.
- `url`: the web page URL when the element is web content (`AXURL` of the web
  area), otherwise `app://<bundleId>`. `pathname`: the window title.
- `mode`: `element`, `window` (fallback) or `region`.
- `project`: set in phase 2 by routing; null until then.

## Dictation

Same contract as the web annotator: Ofide's local API. Production is
`http://127.0.0.1:12321`, Ofide Dev is `http://127.0.0.1:12322`
(configurable). `POST /dictate` starts recording; `POST /dictate-stop` stops
it, transcribes, and pastes into the focused field (200 when pasted; 409 means
no active dictation; 422 means silence). The comment field must be focused and
the app frontmost when the paste lands. See `~/apps/ofide/README.md` for the
full API. If Ofide is not running, show that next to the button.

## Permissions

- **Accessibility:** needed for the hit test. Check
  `AXIsProcessTrustedWithOptions` on launch. If it is missing, show a clear
  onboarding window with a button that opens the right Settings pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`).
- **Screen Recording:** needed for capture. Check with
  `CGPreflightScreenCaptureAccess`, request with
  `CGRequestScreenCaptureAccess`. macOS may need an app relaunch after the
  grant; say so.
- Grants are tied to the bundle id and the code signature. Unsigned or
  ad-hoc-signed rebuilds lose them and prompt again. Always sign with the same
  identity (see Build).
- The global hotkey uses Carbon `RegisterEventHotKey`, which needs no
  permission. Do not use a `CGEventTap`; it would need Input Monitoring.

## Tech and layout

- Swift 6, SwiftUI for windows and settings, AppKit for the overlay panels and
  the menu bar (`NSStatusItem`). Minimum macOS 15. No third-party
  dependencies in phase 1.
- Swift Package Manager, not an Xcode project, so the repo stays text-only and
  diffable. One executable target plus one library target for testable logic:

```
Package.swift
Sources/Annotator/            # app: entry point, menu bar, overlay, panels
Sources/AnnotatorCore/        # pure logic: geometry, AX snapshot model, payload, routing, server client
Tests/AnnotatorCoreTests/
Resources/Info.plist
Resources/Annotator.entitlements
scripts/bundle.sh             # builds the .app bundle and signs it
```

- Bundle id: `com.nckrtl.annotator`. App name: `Annotator`. `LSUIElement`
  true (no Dock icon). Set `NSScreenCaptureUsageDescription` to a short
  reason.
- Keep accessibility reads in a small `AXReader` with a value type for the
  snapshot, so the rest of the code never touches `AXUIElement`.

## Build

```bash
swift build -c release
swift test
scripts/bundle.sh          # writes build/Annotator.app and signs it
open build/Annotator.app
```

`scripts/bundle.sh` must:

1. Run `swift build -c release`.
2. Create `build/Annotator.app/Contents/{MacOS,Resources}`, copy the binary
   and `Resources/Info.plist`, and set `CFBundleShortVersionString` from
   `git describe --tags --always`.
3. Sign with hardened runtime:
   `codesign --force --options runtime --entitlements Resources/Annotator.entitlements --sign "$SIGNING_IDENTITY" build/Annotator.app`.
   `SIGNING_IDENTITY` defaults to `Apple Development: Nick Retel (G9Y9TT23QF)`,
   which is valid on this MacBook. The Mac mini has
   `Nick Local Code Signing` instead. Fail loudly if the identity is missing
   (`security find-identity -v -p codesigning`). Over SSH the login keychain
   is locked (`errSecInternalComponent`); unlock it first or sign locally.
4. Verify: `codesign --verify --deep --strict build/Annotator.app`.

The app is not sandboxed: accessibility of other apps does not work in the
sandbox. Entitlements stay minimal (no `com.apple.security.app-sandbox`).

Install for daily use by copying `build/Annotator.app` to `/Applications`.
After a signing identity change, reset grants with
`tccutil reset Accessibility com.nckrtl.annotator` and
`tccutil reset ScreenCapture com.nckrtl.annotator`, then grant again.

## Testing

- Unit tests (`swift test`) for `AnnotatorCore`: AppKit to global
  top-left coordinate conversion on multi-screen layouts (including a screen
  left of or above the main one, and Retina scale), element path formatting,
  payload encoding (matches the JSON above), screenshot size limiting, and the
  server client's handling of 201/200/410/413/5xx.
- Manual checks before you call phase 1 done, with a server running:
  1. A native app (Finder, Mail or System Settings): hover shows tight
     highlights; a click posts a record with a real `ax.path`.
  2. An Electron app (Conn, Slack or VS Code): elements resolve after the
     first hover (`AXManualAccessibility`).
  3. A web page in Safari or Chrome: `url` is the page URL.
  4. A second monitor, if connected: highlight and crop line up.
  5. Server stopped: the panel says so and the comment is not lost.
  6. Permissions revoked: onboarding appears and says what is missing.
- Check the posted record with `curl -s http://127.0.0.1:29703/annotations`
  and open the screenshot data URL to confirm the crop.

## Phases

**Phase 1 (build this first):** menu bar item, hotkey, permission onboarding,
overlay with element highlight and window fallback, region mode, comment panel,
capture, POST with local retry, live queue counts in the menu, settings
(server URL, hotkey, Ofide URL). Dictation button if it stays small.

**Phase 2 (after user feedback):**
- Pins: numbered markers for open annotations, shown on the overlay over the
  window they belong to (store window id and the position relative to the
  window). Hide them when that window is not on screen; accept ofide when
  content moves.
- Project routing: rules in `~/.config/annotator/routes.json` map bundle id,
  window title pattern or URL prefix to a project name and root folder. Set
  `native.project` on each record. Unmatched records go to an inbox project.
  Agents filter on it.
- Full-window screenshot next to the element crop.

## Prior art to read

- `~/apps/annotator/`: the web annotator. Read `bin/serve.mjs`,
  `bin/store.mjs` and `bin/QUEUE-SKILL.md` (how agents drain the queue). Match
  its comment and pin behavior where it applies.
- `~/apps/conn/apps/desktop/src/snapShot/`: Conn's (the T3 Code fork's) SnapShots feature
  (TypeScript). `MacSnapShot.ts` and `SnapShotAccessibility.ts` read window
  accessibility context and capture regions on this Mac. Use them as a
  reference for what works; do not copy the Node approach.
