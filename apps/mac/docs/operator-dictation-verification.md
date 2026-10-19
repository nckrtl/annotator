# Operator dictation recovery — 2026-10-14

The screen lock came from a blocking overlay surviving the comment and its errors.
It was not introduced by the Projects or menu icon changes.

## Evidence

- At `f9f09f2`, `OverlayPanel.ignoresMouseEvents` was false. Frozen panels stayed
  above the menu bar while a comment was open. `Dictation.finish` and `watch`
  changed the phase/error after failure but did not close those panels.
- Escape called `cancel_comment`, whose `comment_closed` sent `resume` and
  registered Escape again. It closed the draft but returned to a full-screen
  mouse target. `helper_event("escape")` also ignored Escape while a draft existed.
- `Dictation.swift`, `Bridge.swift`, and `Overlay.swift` have no changes between
  `590a4f6` and `f9f09f2`. The same lifecycle predates `e4990c1`, `946581a`, and
  `d3d381b`. The later changes to `WindowOpener`, menu sizing, Projects, and the
  status image do not change this path.
- HTTP runs in async Rust tasks. Swift awaits pipe continuations. AX reads run
  on `AXReader`'s background queue with a 0.25 s messaging timeout. No synchronous
  Local API wait on the main actor was found. There was no trace of Nick's process
  to establish an unrelated main-thread hang.
- The old HTTP start and stop shared a 125 s timeout. Swift polling had 800
  iterations of 150 ms *plus request time*. The bridge allowed 135 s per request.
  Those were long waits, not a reliable two-minute overall deadline.

The screenshot's “sent no text” message is specifically the path after a successful
stop reply followed by no change in the comment. A silence (422), absent recording
(409), or unauthorized (401) response would have produced a different message.
It does not establish whether audio detection failed.

Native Operator's `ControlRoutes`, `ControlHandler`, `StatusSnapshot`, and
`ControlConfig` agree with Annotator's routes, token header, status names,
`cancelledAt` milliseconds, and 409/422 codes. One response field was ignored:
`GET /status` can return 200 with a nonempty `error`. That is now a failure.

Operator's native helper saves `FrontmostPID.current()` at recording start,
requires that PID still be frontmost for paste, and dispatches Cmd-V to its
focused element. A 200 stop response acknowledges dispatch, not delivery to
Annotator's field. Annotator used a non-activating panel, called `NSApp.activate`,
and waited a fixed 200 ms without checking workspace PID or the first responder.
That is a plausible cause of the missed paste, now guarded by an activating panel
and verified focus. It is not proven for Nick's recording: the VM's local
`helpers.log` ends on October 11 and has none of the supplied 08:57:32Z event.
The host's target/workspace PID and paste-result lines are still needed.

The old independent app and URL settings could select the Dev API or pair one
app's token with the other's port. The host's saved selection was not available
in the VM. This possibility is removed: production port 12321 and production
control.json are fixed, and redirects cannot send the token to another origin.

## Change and checks

Selection now removes the full-screen panels before capture. A draft is a small,
activating panel; errors preserve its text and allow typing. Escape closes it and
ends selection. Dictation has independent short request deadlines, progress limits,
late-response rejection, cancellation cleanup and bounded step logs. The helper's
15 s inactivity watchdog closes its panels; a background backstop exits the helper
one second later if its main actor cannot run. Parent exit and EOF remove it too.

The live Rust code under `src-tauri` remains. `main.rs` includes `operator.rs`, and
`commands.rs` calls it for the SwiftUI host. It reads the token from
`com.nckrtl.operator/control.json` and sends it as `X-Operator-Token`. Settings store
`operatorEnabled` and `operatorAutoStart`.

Verification includes fake HTTP silence/409/401/500/504 replies, slow/no reply,
dropped response bodies, malformed status and HTTP-200 worker errors; Swift tests
cover lost paste, start/stop deadlines, cancellation races, core crash, focus refusal,
stalled progress, late replies and typing recovery. Helper tests cover inactivity,
renewal/disarming and a deliberately blocked main actor. The core smoke checks
selection release and Escape as well as queue, storage, routing and shutdown.

The desktop was initially locked (`CGSSessionScreenIsLocked=Yes`, loginwindow
held focus). The guard refused start, and ScreenCaptureKit returned -3811. After
unlock, the focus fixture still exposed the old activation call's weakness.
Explicit activation with `activate(ignoringOtherApps: true)` before making the
panel key passed the frontmost-PID and editable-first-responder checks. Native
light/dark screenshots and menu smoke checks then passed. This reproduces a focus
failure in the VM, but does not prove Nick's October 14 paste destination.

A real native speech check used the available `operator-headless` binary, the
signed Operator `80a9d1d` helpers, the existing model cache (linked, not copied),
and a 2.2 s synthetic `dictation.wav`. The helper acknowledged test-audio mode,
but the coordinator timed out after 40 s in `arming: Opening microphone…`.
No transcript or audio-to-paste success is claimed. Headless itself never pastes.
A system dialog subsequently held focus (UserNotificationCenter); the next focus
check correctly refused start. The computer-use tool blocked that system app, so
the dialog was left for the user to dismiss. No new permissions were granted.
The fake API tests and the production comment-panel fixture cover the recoverable
failure path independently of that environment limitation.
The final saved panel fixture result passed real frontmost-PID and key-field
checks, missing-paste recovery, typing, responder-chain paste, and Escape. This
uses a fake API and does not establish native Operator audio-to-paste success.

Native ScreenCaptureKit captures cover Settings, the missing-paste error and all
36 demo light/dark pairs, including the overlay renderer. The earlier offscreen
renders are retained separately. The Operator settings have only the two saved
choices; no app picker or editable URL remains. The error fits beside the field
without clipping controls. The delivery evidence folder records exact test counts,
signing requirements, the ZIP checksum and remaining live-test limits.
