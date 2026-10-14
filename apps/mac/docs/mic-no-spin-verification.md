# Microphone progress — 2026-10-14

Based on Annotator `8295ad2` and unchanged DesignKit `8e9b37c`.

The comment footer in `app/Sources/AnnotatorApp/Panels.swift:99` explicitly passed
`spinning: model.dictation == "transcribing"` to `KitIconButton(.microphone, …)`.
DesignKit's `Controls.swift:23` forwards that flag to `KitIconImage`. Heroicons
then use `KitSpin` in `Icons.swift:189–207`, which repeats a full rotation every
second. Its SF Symbols path uses `.symbolEffect(.rotate)` at line 182.

Removed that argument. The microphone stays still. The existing “Transcribing…”
label now has a separate 12-point `KitStatusIcon(.working)` beside it. Its
`Status.swift:55–59` implementation pauses the timeline and uses zero rotation
with Reduce Motion. The label supplies the accessible status; the extra ring is
hidden from accessibility. Recording, stop, focus, and disabled-state behavior
are unchanged. The starting revision uses a neutral recording microphone, not
a red one; this change preserves it.

No DesignKit change or branch is needed. No helper packaging or install script
was changed. `Controls.swift`, `Sidebar.swift`, and `Shell.swift` are untouched.

## Sweep

Searched Mac Swift/AppKit sources and the web package for rotation effects,
symbol effects, repeat-forever animation, spin flags, and CSS rotation.

- The comment microphone was the only spinning non-progress icon in Annotator.
- `packages/annotator/src/components/AnnotationPopup.tsx:439` uses a dedicated
  SVG progress ring while dictation starts or transcribes. The rotation is in
  `src/shadow.css:118–124`. It is a progress indicator, so it is unchanged.
- No other Mac rotation or spin call sites were found.
- Vault uses the same `KitIconButton` for sync in `Vault/VaultWindow.swift:54`,
  with `spinning: vault.isSyncing`. Its other uses are ordinary buttons.
- Operator uses `KitIconButton` in `AppsChooser.swift`, `TriggersPage.swift`, and
  `LocalAPIGroup.swift`. None of these callers enables spinning. Neither app
  was changed.

## Verification

- `scripts/test.sh`: 30 Swift helper tests, 87 Rust tests (one existing ignored
  test), and 16 Swift app tests passed.
- `scripts/smoke-core.py`: passed settings, permissions, hotkeys, project CRUD,
  routing, capture-to-submit, screenshots, live queue, offline retry, deletion,
  malformed commands, and EOF cleanup.
- `scripts/check-dictation.sh`: passed with real foreground and first-responder
  checks enabled. Missing-paste recovery, typing, responder-chain paste, overlay
  release, and Escape passed.
- The check now captures the real panel through ScreenCaptureKit: idle,
  recording, ten waiting frames across about two seconds, and settled paste.
  Light/dark and normal/Reduce Motion produce 52 frames. Operator replies and
  pasted text are fixtures; this does not test live audio transcription.
- Every waiting microphone crop and label crop is pixel-identical within each
  sequence. The progress crop changes in normal motion (10 light variants,
  9 dark variants) and is pixel-identical with Reduce Motion in both appearances.
- Reviewed all waiting footers and the idle/recording/waiting/pasted panels.
  The microphone stays upright. The separate ring fits without clipping or
  shifting the microphone or Submit button. The disabled mic is dimmer while
  waiting, as before. Text remains legible in light and dark.
- Release build signed with `Apple Development: Nick Retel (G9Y9TT23QF)`.
  Deep/strict verification passed. App, core, and native helper designated
  requirements match the `4de8043` delivery and the installed app under
  `~/Applications` exactly. Bundle ID remains `com.nckrtl.annotator`.

Evidence is in `/Volumes/My Shared Files/Agent/annotator/mic-no-spin/`:
`frames/sequence.csv`, all 52 PNGs, light/dark state sheets and waiting strips,
`frame-check.txt`, `dictation-panel-check.txt`, `REQUIREMENTS.txt`, and test/build
logs. The debug-only frame fixture overrides the SDK's Reduce Motion environment
setter; it never changes the user's system preference.
