# Annotator for macOS

A native macOS menu bar app that lets the user annotate anything on screen.
They press a hotkey, hover, and see the UI element under the cursor
highlighted. They click it, type or dictate a comment, and submit. The app
captures a screenshot and the element's accessibility details, then posts the
annotation to the same queue the web annotator (`@nckrtl/annotator`) uses.
Coding agents claim the queue, make the change, and mark each item done.

It is the system-wide version of the web annotator. It works on native apps,
Electron apps, browsers and anything else on screen.

Phase 1 is built: a Tauri 2 app with React views, a Rust core and a Swift
helper, on Ofide's stack (`~/apps/ofide/mac`). Read this file before you
change anything.

## Status and scope

- Repo: `~/apps/annotator-mac` (this folder). Git is initialized; there is no
  remote yet. Ask the user before you create one.
- The web package lives at `~/apps/annotator`. Do not change it from here.
  This app only talks to its server over HTTP.
- Phase 1 is done. Ask the user before you start phase 2.

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

Ofide's stack and layout, so code copies between the two apps:

```
src/                  # React views, one Vite entry; the window label picks the view
  ui.tsx, ui.css      # copies of Ofide's components and tokens: keep them identical
  components.tsx      # generic components that can move to Ofide
  menu/ comment/ settings/ onboarding/ detail/
src-tauri/            # Rust core: all state and I/O (server, queue, retry store,
                      # projects, Conn, Ofide, hotkey, panels, windows)
native/               # Swift helper `annotator-native`: Accessibility, overlay,
                      # hit test, capture, DevTools DOM lookup (SwiftPM)
scripts/              # build, sign, install, test, Conn headless server
docs/port.md          # the contract between the three parts
```

- Rust and the helper talk in JSON lines (`docs/port.md` §1). React talks to
  Rust with `invoke` commands and `state` events (§2).
- The menu and comment panels are webviews in native `NSPanel`s
  (`src-tauri/src/panels.rs`), so they open over full-screen apps and the
  comment field can take Ofide's paste.
- Windows use Ofide's shell: no title bar, a vibrant sidebar, the title on the
  right, resizable.
- The global hotkey uses Carbon `RegisterEventHotKey`; no `CGEventTap`.
- Bundle id: `com.nckrtl.annotator`. `LSUIElement` true. Minimum macOS 15.
  The helper is in `Contents/Resources/annotator-native` and runs under the
  app's permission grants.
- Keep `ui.tsx` and `ui.css` identical to Ofide's; put app styles in
  `src/app.css`. Compare with
  `diff ~/apps/ofide/mac/src/ui.tsx src/ui.tsx`.

## Build

```bash
bun install
scripts/test.sh            # swift test (native), cargo test, tsc, bun test
scripts/install.sh         # builds, signs, installs /Applications/Annotator.app, starts it
```

`scripts/build-app.sh` builds the helper (`scripts/build-native.sh`), runs
`bun run tauri build`, and signs inside out (`scripts/sign-app.sh`): the
helper, then the app, with the hardened runtime. The identity is in
`scripts/signing.sh`: `Apple Development: Nick Retel (G9Y9TT23QF)`, or
`SIGNING_IDENTITY`. The build fails if the identity is missing. Over SSH the
login keychain is locked (`errSecInternalComponent`); unlock it first or sign
locally.

The app is not sandboxed: accessibility of other apps does not work in the
sandbox. Entitlements stay empty.

macOS keeps the Accessibility and Screen Recording grants for this bundle id
and certificate. After a signing identity change, reset them with
`tccutil reset Accessibility com.nckrtl.annotator` and
`tccutil reset ScreenCapture com.nckrtl.annotator`, then grant again.

Logs: `~/Library/Logs/Annotator/annotator.log`. Settings:
`~/Library/Application Support/com.nckrtl.annotator/settings.json`.

## Testing

- `scripts/test.sh` runs every suite:
  - `swift test --package-path native`: coordinates on multi-screen layouts,
    element labels, record encoding, screenshot size limits, DOM redaction.
  - `cargo test` in `src-tauri`: server client (201/200/410/413/5xx), queue,
    retry store, projects and prompt text, Conn, Ofide, panel placement,
    URL and id checks.
  - `bunx tsc -b` and `bun test scripts/`: hotkey, dictation state machine,
    menu sections.
- For layout work without the app, run `bun run dev` and open
  `http://127.0.0.1:1430/preview.html?window=menu` (also `comment`,
  `settings`, `onboarding`, `detail-<id>`). It mocks the Rust side.
- Manual checks, with a server running:
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
