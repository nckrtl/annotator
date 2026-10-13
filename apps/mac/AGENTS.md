# Annotator for macOS

A native macOS menu bar app that lets the user annotate anything on screen.
They press a hotkey, hover, and see the UI element under the cursor
highlighted. They click it, type or dictate a comment, and submit. The app
captures a screenshot and the element's accessibility details, then posts the
annotation to the same queue the web annotator (`@nckrtl/annotator`) uses.
Coding agents claim the queue, make the change, and mark each item done.

It is the system-wide version of the web annotator. It works on native apps,
Electron apps, browsers and anything else on screen.

The app uses SwiftUI on DesignKit, a Rust service process and a Swift capture
helper. Read this file before you change it.

## Status and scope

- Repo: `apps/mac` (this folder) in the public `nckrtl/annotator` monorepo,
  checked out at `~/apps/annotator`. The root `AGENTS.md` covers the layout
  and the release rules.
- The web package lives in `packages/annotator`. Do not change it from here.
  This app only talks to its server over HTTP.
- The current app includes project routing and Conn sessions. Preserve them.
- The UI conversion is authorized. No webview is needed in the Mac app.

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
   margin. Exclude this app's own windows
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
(`validId` in `packages/annotator/bin/store.mjs`). Use a lowercase UUID string.

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
- `project`: the name of the first matching route, or Inbox when none matches.

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

## UI decisions (DesignKit conversion)

Follow `~/apps/design-kit/DESIGN.md` draft 2. DesignKit requires macOS 26.
The local package is `~/apps/design-kit/DesignKit`; set `DESIGN_KIT_PATH` to
use another checkout. Do not copy its controls into this repository.

- Library and detail: one SwiftUI `Window`, hidden title bar, `KitWindowChrome`,
  `KitShell` with a 220 pt sidebar, a 300 pt list and a detail column. The default
  size and minimum size come from DesignKit. Screenshots are native images.
- Settings and Projects: pages in the shell, not separate windows. Settings
  uses `KitGroup` and `KitRow`. The project editor is a `KitSheet`.
- Menu: SwiftUI `MenuBarExtra` with window style. Library, Projects and Settings
  provide the full queue, server and agent controls.
- Comment: SwiftUI hosted in a key-capable AppKit `NSPanel`, above the capture
  overlay and visible over full-screen apps. `NSTextView` preserves input methods,
  Ofide paste, Return to submit, Shift-Return for a line, and Escape to cancel.
- Permissions: a frosted SwiftUI prompt in an AppKit window.
- Overlay: keep the existing AppKit panels, hit testing, region selection and
  ScreenCaptureKit capture. Its neutral outline has a contrasting halo, so it
  stays visible on arbitrary content. It is desktop content, not a web page.
- Browser annotation canvas: stays in the independent npm package. The Mac app
  only exchanges records with its HTTP server. No package imports.
- No Mac surface is a web page, so Tauri and React are removed from the Mac app.
- Notices always sit inside a `KitGroup`, with primary text. Only the icon
  carries warning or error color; never use tinted notice boxes.
- Identity: a neutral pencil mark with an annotation dot; numbered tiles recur
  in the library. Controls, spacing, type and shell come from DesignKit.

```
app/                  # SwiftPM: AnnotatorApp (SwiftUI/AppKit), AnnotatorCore (Foundation)
src-tauri/            # historical directory name; now a plain Rust executable, no Tauri
native/               # Swift capture helper and its UI-free record/geometry target
scripts/              # build, sign, install, test, UI snapshots, Conn server
Snapshots/designkit/  # generated light/dark UI captures (ignored by git)
docs/port.md          # process contracts
```

Rust keeps settings, HTTP, SSE/polling, queue, pending/retry storage, routing,
Conn, Keychain and Ofide serialization. It imports neither SwiftUI nor AppKit.
`AnnotatorCore` keeps JSON framing, the pipe client and dictation lifecycle;
it imports neither SwiftUI nor AppKit. Only the UI target owns windows, Carbon
shortcuts, focus and file pickers.

The SwiftUI host starts `Contents/Resources/annotator-core` over inherited
stdin/stdout pipes. The core starts `annotator-native` beside it. No network
listener is added. `ANNOTATOR_HOST_PID` tells the helper to exclude all three
processes from hit testing and capture. Closing the host's pipe stops the core
and its helper. A core failure is visible and fails all outstanding requests.

Bundle id stays `com.nckrtl.annotator`; `LSUIElement` remains true. Settings,
project routes, pending comments and tokens keep their existing locations.

## Build and install

```sh
bun install --frozen-lockfile
bun run build                  # type-check and build SwiftUI
scripts/test.sh                # helper, Rust, bridge and dictation tests
scripts/build-app.sh --debug   # build/debug/Annotator.app; ad-hoc signing
scripts/build-app.sh           # build/release/Annotator.app; Nick's identity
scripts/install.sh             # Nick's Mac only, only when explicitly asked
```

Builds copy DesignKit’s Heroicons resource bundle, the Rust core and the capture
helper into the app. `sign-app.sh` signs the two child executables before signing
the app with the hardened runtime. The identity remains
`Apple Development: Nick Retel (G9Y9TT23QF)`, or `SIGNING_IDENTITY`.
An unsigned/ad-hoc VM build does not inherit Nick's permission grants.
The app is not sandboxed. Entitlements stay empty.

`install.sh` builds the signed release, replaces `/Applications/Annotator.app`,
registers it and starts it. Do not run it on the VM. Do not reset privacy grants
or change signing identities as a shortcut for testing.

CI checks out the private DesignKit repository using `DESIGN_KIT_TOKEN` (a
read-only repository secret), and sets `DESIGN_KIT_PATH` to that checkout.

## Verification

- `scripts/test.sh`: capture geometry and redaction; Rust HTTP/queue/retry,
  routing, Conn and Ofide; Swift pipe framing and dictation races.
- `scripts/smoke-core.py`: real Rust core, temporary home and loopback server,
  controlled helper fixture. Tests saved settings, permission and hotkey events,
  capture-to-submit, routing, screenshots, live queue, offline retry, deletion,
  malformed commands and cleanup on EOF. No user data or server is used.
- `scripts/snapshots.sh [absolute-output-directory]`: debug-only demo data;
  no helpers, servers or user settings. Captures every page, panel, editor,
  empty/error state and minimum-size layout in light and dark. ScreenCaptureKit’s
  current-process API captures the actual windows, including glass and native
  chrome, without a Screen Recording grant.
- Real capture and dictation still require granted macOS permissions and a
  running Ofide. Check hover/click, Option-drag, Escape, paste-before-submit,
  multi-display placement and full-screen panels on a signed installation.

Logs: `~/Library/Logs/Annotator/annotator.log`. Settings:
`~/Library/Application Support/com.nckrtl.annotator/settings.json`.

## Original delivery phases

Phase 1 is implemented: menu bar item, hotkey, permission onboarding,
overlay with element highlight and window fallback, region mode, comment panel,
capture, POST with local retry, live queue counts in the menu, settings
(server URL, hotkey, Ofide URL). Dictation button if it stays small.

Possible follow-ups (project routing is already implemented):
- Pins: numbered markers for open annotations, shown on the overlay over the
  window they belong to (store window id and the position relative to the
  window). Hide them when that window is not on screen; hide them when
  content moves.
- Project routing: rules in `~/.config/annotator/routes.json` map bundle id,
  window title pattern or URL prefix to a project name and root folder. Set
  `native.project` on each record. Unmatched records go to an inbox project.
  Agents filter on it.
- Full-window screenshot next to the element crop.

## Prior art to read

- `packages/annotator/`: the web annotator. Read `bin/serve.mjs`,
  `bin/store.mjs` and `bin/QUEUE-SKILL.md` (how agents drain the queue). Match
  its comment and pin behavior where it applies.
- `~/apps/conn/apps/desktop/src/snapShot/`: Conn's (the T3 Code fork's) SnapShots feature
  (TypeScript). `MacSnapShot.ts` and `SnapShotAccessibility.ts` read window
  accessibility context and capture regions on this Mac. Use them as a
  reference for what works; do not copy the Node approach.
