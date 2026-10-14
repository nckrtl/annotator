# Native app process contracts

The SwiftUI host owns windows, menu-bar UI, Carbon shortcuts and focus. Rust owns
settings, queue and integrations. The capture helper owns Accessibility,
ScreenCaptureKit and the desktop overlay. No Mac webviews remain.

- `app/Sources/AnnotatorApp`: SwiftUI/AppKit views on DesignKit.
- `app/Sources/AnnotatorCore`: UI-free JSON pipe client and dictation lifecycle.
- `src-tauri`: historical directory name; now a plain Rust executable.
- `native`: the existing capture helper and its UI-free record target.

## Host protocol (SwiftUI ↔ Rust)

Inherited stdin/stdout pipes, one JSON object per line. No listening socket.
Requests: `{"id":"uuid","command":"get_state","args":{}}`.
Replies: `{"id":"uuid","result":...}` or `{"id":"uuid","error":"message"}`.
Events: `{"event":"state","payload":...}`. Events and replies can interleave;
request IDs match replies. Commands and camelCase argument names remain stable.
Malformed arguments and unknown commands return errors. Host requests time out
after 135 seconds by default. Dictation wraps these requests in independent
5-second deadlines (18 seconds for stop) and cancels abandoned continuations. EOF stops the core
and the capture helper. Logs go to stderr and the existing log file, never stdout.

UI events, in addition to the state and comment events below:

- `navigate {page,id?}` opens a page or selects an annotation in the library.
- `onboarding`, `alert {title,message}`, `quit`, `relaunch` request host actions.
- `show-comment {x,y,width,height}` uses global top-left points; `hide-comment`
  invalidates pending placement. `hide-menu` hides the menu-bar window.
- `register-hotkey {slot,keyCode,modifiers}` and `unregister-hotkey <slot>` are
  handled on the main thread. Slot 1 toggles, slot 2 is Escape during selection and while a comment is open. Escape closes
  the local panel immediately, then cancels dictation and tells the core to stop.
- Host sends `hotkey_pressed {slot}` and `hotkey_error {message}`.
- Host sends `menu_opened` to refresh permissions and projects.
- `comment_origin {target,screens,mouse,size}` returns `[x,y]` in AppKit points.
  Screens carry `frame` and `visible` rects in AppKit points. The core keeps its
  tested multi-display placement; the UI sends the current screen and panel sizes.

The host passes `ANNOTATOR_HOST_PID` to the core and helper. The helper excludes
that pid, its parent and itself from capture and hit tests. `ANNOTATOR_HELPER`
may select a controlled helper fixture in integration tests.

## 1. Helper protocol (Rust ↔ `annotator-native`)

JSON lines. Commands on stdin `{"action": …}`, events on stdout `{"type": …}`. Rust re-emits
every helper event as a host event of the same name only where listed below; otherwise Rust
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
| `selected` | see below | the user clicked an element, a window or dragged a region; the capture is done; the overlay was removed before capture |
| `clickWhileFrozen` | `x, y` | a click on the overlay while frozen (comment panel open) |
| `overlay-timeout` | | the helper released its overlay after 15 s without input |
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
  defaults from `src-tauri/src/settings.rs` in camelCase: `serverAutoStart, serverURL,
  operatorEnabled, operatorAutoStart, hotkey {keyCode, modifiers (Carbon flags)}`.
  Unknown keys, such as those of the removed Conn sessions, are ignored.
- Projects: `~/.config/annotator/routes.json`, same format as `src-tauri/src/projects.rs`:
  `{id, name, root, instructions, bundleIds, urlPrefixes}`. A project's old `notes` key is
  read as `instructions`. Window title rules were removed; an old `titleContains` key is ignored.
- Retry store: `~/Library/Application Support/Annotator/{pending,failed}/<id>.json` (unchanged).
- Local server: `src-tauri/src/local_server.rs`.

### Events Rust emits (to all windows)

- `state`: the whole `AppState` (below), after every change. Windows also call `get_state` once.
- `queue`: the full `QueueItem[]` list from the server (detail windows read their item from it).
- `comment-opened`: `CommentTarget` (to the `comment` window), when the panel opens.
- `comment-finish`: (to `comment`) a click elsewhere: finish dictation, then call
  `comment_finish_done { submit: bool, text }`.
- `comment-cancel`: stop dictation when annotate mode ends.

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
  projects: { id: string; name: string; root: string }[]; projectsError?: string;
};
type CommentTarget = { label: string; mode: "element" | "window" | "region"; captureError?: string;
  dictation: null | { url: string; app: string; autoStart: boolean } };
```

### Commands

Menu: `get_state`, `toggle_annotating`, `server_control {action: "start"|"stop"|"restart"}`,
`show_server_log`, `open_server`, `open_settings {tab?: "general"|"projects"}`, `open_onboarding`,
`open_annotation {id}`, `clear_open` (deletes all open items; returns `{failed: number}`),
`retry_now`, `show_failed`, `copy_prompt {scope: "inbox"|"all"|projectId}`,
`hide_menu`, `quit_app`.

Comment: `submit_comment {text}` (closes the panel at once, posts in the background),
`cancel_comment`, `comment_finish_done {submit, text}`, `ofide {action: "status"|"start"|"stop"|"cancel"}`
(proxies the live `src-tauri/src/ofide.rs`; returns its JSON or an error string).
`release_overlay` preserves the draft and ends selection. `stop_annotating` also
closes the comment. The internal `ofide` command name is retained.

Settings: `get_settings`, `save_settings {settings}` (re-registers the hotkey, restarts the queue
when the URL changed), `hotkey_recording {recording: bool}` (unregister the toggle hotkey while the
recorder listens), `get_projects`, `save_projects {routes}` (returns an error string on failure),
`last_target_app` → `{name, bundleId} | null`.

Onboarding: `request_permission {kind: "accessibility"|"screenRecording"}`,
`open_privacy {kind}` (opens the Settings pane), `relaunch`.

Detail: `get_queue` → `QueueItem[]` (screenshots null), `get_screenshot {id}` → string or null, `delete_annotation {id}`.

Folder selection uses the host’s `NSOpenPanel`. See AGENTS.md for window decisions.

### Flows (port from `AppController.swift`)
- Toggle (hotkey, menu): without both permissions open onboarding; else `annotate on`,
  register Esc; menu bar icon shows annotating.
- `selected` → release the overlay, remember the record, keep Escape registered,
  open the activating comment panel next to `frame`.
- Submit → fill comment and project, save to the retry store, POST, hide the panel,
  unregister Escape. Start a new selection with the hotkey or menu.
- Escape → close the panel immediately, cancel dictation, end selection.
- The old `resume`/`selectAt`/`clickWhileFrozen` protocol remains for compatibility;
  normal comments no longer use it or keep a full-screen click target.
- Queue: SSE + polling (`QueueMonitor.swift`); retry pending when reachable.
- Menu bar: `pencil.tip.crop.circle`, with its filled variant during selection,
  and the open count. Identity and signing remain unchanged.

## 3. SwiftUI views

The library combines list and detail. It sorts annotations by newest number,
which preserves the queue's timeline rather than sorting comments alphabetically.
Search, filters, screenshots, copy and confirmed deletion live here. Settings,
Projects and the menu provide server controls, retries, failed files and agent
prompts. Annotator starts no agent sessions: users paste a copied prompt into any agent. The editor preserves project order because routing uses the
first match. Saved locations stay the same. Dictation setting keys migrate as described in AGENTS.md.

The comment owns one `Dictation` session. Start/stop/cancel stay serialized in
Rust; Swift also waits for an old cancellation before starting a new recording.
A session generation rejects late responses. Submit waits for start, then stop,
then a changed and settled text field. A missing paste or silence keeps the
comment open with an editable field and no blocking overlay. Operator cancellation closes it. Return submits, Shift-Return inserts
a line, and marked text keeps input-method composition. Escape cancels.

`ANNOTATOR_UI_DEMO=1` works only in debug builds. It uses made-up data and starts
no core, helper, server or dictation session. Snapshot mode captures the actual
windows through ScreenCaptureKit's current-process API, without a TCC grant.
