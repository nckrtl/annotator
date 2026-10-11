# Port to Tauri: the contract between the three parts

The Swift app (`Sources/`, `Tests/`) is the reference. Every feature it has must exist in the port,
with the same behavior and the same texts (Simplified Technical English: short, active, plain).
Read the Swift file named in each section before you write its replacement. When this document
and the Swift app disagree on behavior, the Swift app wins; when they disagree on the interface
between the parts, this document wins.

Parts:
- `native/`: the Swift helper `annotator-native` (SwiftPM). Accessibility, overlay, capture, DevTools.
- `src-tauri/`: the Rust core. All state and I/O. Windows are views of it.
- `src/`: React views. One Vite entry (`src/main.tsx`) renders by window label.

Already there (from the spike, reuse and extend): `src-tauri/src/{main,panels,helper}.rs`,
`native/Sources/AnnotatorNative/main.swift` (JSON-lines loop), `src/ui.tsx` + `src/ui.css`
(copied from Ofide; do not edit them, add app styles to `src/app.css`), `scripts/*.sh`.

## 1. Helper protocol (Rust ↔ `annotator-native`)

JSON lines. Commands on stdin `{"action": …}`, events on stdout `{"type": …}`. Rust re-emits
every helper event as a Tauri event of the same name only where listed below; otherwise Rust
handles it.

Commands:

| action | fields | meaning |
| --- | --- | --- |
| `ping` | | answer `online` |
| `permissions` | | answer `permissions` |
| `requestScreenCapture` | | `CGRequestScreenCaptureAccess()`, then answer `permissions` |
| `requestAccessibility` | | `AXIsProcessTrustedWithOptions(prompt: true)`, then answer `permissions` |
| `annotate` | `on: bool` | show or hide the overlay (all screens) |
| `resume` | | the comment panel closed: unfreeze the overlay and hover again |
| `selectAt` | `x, y` (global top-left points) | select at this point as if clicked (moving the comment) |

Events:

| type | fields | meaning |
| --- | --- | --- |
| `online` | | ready |
| `permissions` | `accessibility, screenRecording: bool` | |
| `selected` | see below | the user clicked an element, a window or dragged a region; the capture is done; the overlay is frozen |
| `clickWhileFrozen` | `x, y` | a click on the overlay while frozen (comment panel open) |
| `escape` | | Esc while the overlay has focus (backup for the Carbon Esc hotkey) |
| `log` | `message` | |
| `error` | `message` | |

`selected` fields:
- `record`: the annotation record exactly as `Annotation.swift` encodes it, built by the helper
  with `Annotation(comment: "", target:, screenSize:, screenshot:, project: nil)`. Rust fills in
  `comment` and `native.project` before posting. `id` and `timestamp` are set by the helper.
- `label`: `target.overlayLabel`.
- `mode`: `element`, `window` or `region`.
- `frame`: `{x, y, width, height}` of the target, global top-left points (for the panel placement).
- `captureError`: string or null. On a capture error `record.screenshot` is null.

The helper skips its own windows and Annotator's (`getppid()`) in hit tests and in captures.
Esc while hovering is a Carbon hotkey in Rust (as in `AppController.registerEscape`), released
while the comment panel is open.

## 2. Rust core

Persisted state:
- Settings: `~/Library/Application Support/com.nckrtl.annotator/settings.json`. Fields and
  defaults from `Sources/Annotator/Settings.swift` in camelCase: `serverAutoStart, serverURL,
  ofideEnabled, ofideAutoStart, ofideURL, ofideApp, t3Enabled, t3Endpoint, t3Effort, t3Home,
  t3WindowHome, t3Nudge, t3DefaultModel, hotkey {keyCode, modifiers (Carbon flags)}`.
- Conn sessions: `…/com.nckrtl.annotator/sessions.json` (the former `t3Sessions` value).
- Projects: `~/.config/annotator/routes.json`, same format as `Projects.swift`.
- Retry store: `~/Library/Application Support/Annotator/{pending,failed}/<id>.json` (unchanged).
- Keychain: service `com.nckrtl.annotator.t3`, account = Conn endpoint (unchanged).
- Local server: as `LocalServer.swift`.

### Events Rust emits (to all windows)

- `state`: the whole `AppState` (below), after every change. Windows also call `get_state` once.
- `queue`: the full `QueueItem[]` list from the server (detail windows read their item from it).
- `comment-opened`: `CommentTarget` (to the `comment` window), when the panel opens.
- `comment-finish`: (to `comment`) a click elsewhere: finish dictation, then call
  `comment_finish_done { submit: bool, text }`.
- `menu-opened`: (to `menu`).

```ts
type Tone = "ok" | "warning" | "error";
type QueueItem = { id: string; number?: number; status: string; comment: string; createdAt?: number;
  claimedAt?: number; completedAt?: number; summary?: string; question?: boolean; element?: string;
  elementPath?: string; url?: string; pathname?: string; boundingBox?: Box; screenSize?: string;
  screenshot?: string; component?: string; react?: string; native?: any; agent?: string };
type AppState = {
  health: { tone: Tone; title: string };          // AppController.health
  serverURL: string;
  localServer: null | { busy: boolean; running: boolean; error?: string; hasLog: boolean };
  queueReachable: boolean;                       // false → show "New annotations are saved locally…"
  annotating: boolean;
  hotkey: { keyCode: number; modifiers: number; display: string };
  hotkeyError?: string;
  permissions: { accessibility: boolean; screenRecording: boolean };
  queue: null | { todo: number; inProgress: number; done: number;
    open: QueueItem[]; finished: QueueItem[] };  // without screenshots; same order as QueueSummary
  pending: { count: number; lastError?: string }; failedCount: number;
  conn: { enabled: boolean; lastError?: string; sessions: string[] /* project ids with a session */ };
  projects: { id: string; name: string; root: string }[]; projectsError?: string;
};
type CommentTarget = { label: string; mode: "element" | "window" | "region"; captureError?: string;
  dictation: null | { url: string; app: string; autoStart: boolean } };
```

### Commands (`invoke`)

Menu: `get_state`, `toggle_annotating`, `server_control {action: "start"|"stop"|"restart"}`,
`show_server_log`, `open_server`, `open_settings {tab?: "general"|"projects"}`, `open_onboarding`,
`open_annotation {id}`, `clear_open` (deletes all open items; returns `{failed: number}`),
`retry_now`, `show_failed`, `conn_start {projectId}`, `conn_open {projectId}`,
`conn_pairing_url` (copies it; returns the URL), `copy_prompt {scope: "inbox"|"all"|projectId}`,
`hide_menu`, `quit_app`.

Comment: `submit_comment {text}` (closes the panel at once, posts in the background),
`cancel_comment`, `comment_finish_done {submit, text}`, `ofide {action: "status"|"start"|"stop"|"cancel"}`
(proxies `OfideClient.swift`; returns its JSON or an error string).

Settings: `get_settings`, `save_settings {settings}` (re-registers the hotkey, restarts the queue
when the URL changed), `hotkey_recording {recording: bool}` (unregister the toggle hotkey while the
recorder listens), `conn_save_connection {endpoint, token}` (validates like SettingsView; token to
Keychain; returns the message), `conn_token_saved {endpoint}` → bool, `get_projects`,
`save_projects {routes}` (returns an error string on failure), `choose_folder` → path or null,
`last_target_app` → `{name, bundleId, title, url} | null`.

Onboarding: `request_permission {kind: "accessibility"|"screenRecording"}`,
`open_privacy {kind}` (opens the Settings pane), `relaunch`.

Detail: `get_queue` → `QueueItem[]`, `delete_annotation {id}`.

Windows `settings`, `onboarding` and `detail-<id>` are normal titled windows Rust creates on
demand with `WebviewWindowBuilder` (one per id; opening again focuses it). `menu` and `comment`
are the NSPanels in `panels.rs`.

### Flows (port from `AppController.swift`)
- Toggle (hotkey, menu): without both permissions open onboarding; else `annotate on`,
  register Esc; menu bar icon shows annotating.
- `selected` → unregister Esc, remember the record, open the comment panel next to `frame`
  (below, else above, else near the cursor, clamped to the screen; `CommentPanel.swift`).
- Submit → fill comment and project (`Projects.swift` rules on the record's bundle id, window
  title and url), save to the retry store, POST (`Submitter.swift`), hide the panel, `resume`,
  register Esc.
- `clickWhileFrozen` → emit `comment-finish`; on `comment_finish_done` submit (if text) or drop,
  then `selectAt`.
- Queue: SSE + polling (`QueueMonitor.swift`); retry pending when reachable; Conn nudges
  (`T3Sessions.nudge`).
- Tray: icon `highlighter` (template), plus the open count as the tray title; while annotating
  use a second template icon. The health colour shows in the menu's first line.

## 3. React views

`menu`: everything in `AppController.menuNeedsUpdate`, as a panel (360 wide): health line with
the server URL; server start/stop/restart/log; Start/Stop Annotating with the shortcut; warnings;
"Open n · In progress n" with rows (`AnnotationRow.swift`: status icon, `#n comment`, spinner
in progress; a question shows its own icon); "n more on the server"; Clear Open Annotations…
with an inline confirmation that says what the NSAlert said; a Done disclosure (up to 50);
pending / Retry Now / refused Show…; Conn Sessions (section, one row per project: start, or new +
open; Copy Pairing URL; errors); Copy Agent Prompt (projects, Inbox, All Annotations); Edit
Projects…; `MoreMenu` with Open Server URL, Settings… ⌘,, Quit Annotator ⌘Q. Esc closes.
Long lists scroll inside the panel; the panel height follows the content up to 640.

`comment`: `CommentPanel.swift`, including the whole Ofide dictation state machine (off,
checking, unavailable, idle, recording, transcribing; auto start; submit while recording stops
and waits for the paste; cancel calls `/dictate/cancel` once; Ofide's own Esc handling via
`status.cancelledAt`). ↩ submits, ⇧↩ new line, IME composing respected, Esc cancels.

`settings`: sidebar with General and Projects, content per `SettingsView.swift` and
`ProjectsView.swift`; Ofide grouped-settings structure (`Group`, `Row`, `Disclosure`).

`onboarding`: `Permissions.swift` OnboardingView. `detail`: `AnnotationDetail.swift` and
`Lightbox.swift` (the lightbox inside the window).
