# Liquid Glass header sweep — 2026-10-14

All app-owned header controls now use DesignKit Liquid Glass. Settings puts its
General / Dictation / Conn picker and Save in one capsule, like Projects' Edit / …
group. The sidebar actions, project back button, active searches, comment close,
menu Settings and screenshot Done controls now use the same glass parts.

Annotator branch: `glass-headers`, based on main `c44b564`.
Required DesignKit branch: `glass-header-picker`, based on main `f9c8ac2`.
Required DesignKit commit: `34f2f5d655d0298476efe1e222fbf13ad20879cd`.
Both branches are for the orchestrator to merge. Merge DesignKit first: Annotator's
local Swift package dependency and CI checkout must include that commit.

## Sweep

All paths below are under `app/Sources/AnnotatorApp/`. “Glass” means a
`KitToolbarGroup` with DesignKit toolbar controls. Native macOS window buttons,
menus and dialogs retain system rendering. Form and footer controls are outside
the header rule.

| Header / state | Controls | Before | After | Source / capture IDs |
| --- | --- | --- | --- | --- |
| Shared sidebar, all main pages | Retry/sync; Annotate screen | Plain `KitIconButton`s | One glass group | `MainWindow.swift`; all main-window captures |
| All annotations list | Search, +, … | Glass | Glass retained | `MainWindow.swift`; 01, 36 |
| Open list | Search, +, … | Glass | Glass retained | `MainWindow.swift`; 35 |
| Finished list | Search, +, … | Glass | Glass retained | `MainWindow.swift`; 04 |
| Annotation searches, including no matches | Text field, Close search; +, … | Search field/close plain; actions glass | Glass search capsule; glass actions | `MainWindow.swift`; 03, 37 |
| Project-filtered annotations | Back to project; Search, +, … | Back plain; other actions glass | All glass | `MainWindow.swift`; 30, 38 |
| Project-filtered search | Back; search field/close; +, … | Back and field/close plain | All glass | `MainWindow.swift`; 39 |
| Annotation detail, all statuses | Copy comment / Copied; … → Delete | Glass | Glass retained | `AnnotationDetail.swift`; 01, 04, 36 |
| Empty / missing annotation detail | None | No header controls | Unchanged | `AnnotationDetail.swift`; 02, 17; missing record uses same control-free branch |
| Projects list, empty list, read error | Search, +, … | Glass | Glass retained | `ProjectsPage.swift`; 09, 18, 28, 33 |
| Projects search | Text field, Close search; +, … | Search field/close plain | All glass | `ProjectsPage.swift`; 40 |
| Project detail, including zero counts | Edit; … (prompts, Conn, priority, Delete) | Glass | Glass retained | `ProjectsPage.swift`; 09, 29, 31, 32 |
| Empty project detail | None | No header controls | Unchanged | `ProjectsPage.swift`; 28, 33 |
| Add / Edit project sheet | Title only | No header controls | Unchanged; Cancel/Add/Save remain in footer, runtime picker in form | `ProjectsPage.swift`; 10, 27, 34 |
| Settings: General | General / Dictation / Conn picker; Save / Saved | Bordered `KitPicker`; ink primary button | One glass picker/Save group | `SettingsPage.swift`; 06, 19, 21 |
| Settings: Dictation | Same picker and Save | Same non-glass controls | Same glass group | `SettingsPage.swift`; 07, 21b, 41 |
| Settings: Conn | Same picker and Save | Same non-glass controls | Same glass group; effort picker stays in form | `SettingsPage.swift`; 08, 22, 42 |
| Menu-bar panel: populated, empty, offline, overflow | More actions (⋯) | Plain icon button | Glass ⋯ menu (was Settings) | `Panels.swift`; 11, 26; `menu-check/` |
| Comment panel: normal, recording, capture error, missing paste | Cancel comment (×) | Plain icon button | Glass close control; Escape retained | `Panels.swift`; 14, 15, 16, 16b |
| Permissions: denied / granted | App mark, title and hint; native window close | No app-owned header controls | Unchanged; Allow is in rows, Check again/Done/Relaunch in footer | `Panels.swift`; 12, 13; `menu-check/` real permission window |
| Offline / empty annotation collection | Same list toolbar | Glass | Glass retained; sidebar fixed | `MainWindow.swift`; 05, 17 |
| Screenshot viewer sheet | Done | `.kitSecondary` | Glass Done; Escape retained | `AnnotationDetail.swift`; 20 |
| Delete annotation / clear open / delete project confirmations | System dialog actions | Native; no custom header | Unchanged | `AnnotationDetail.swift`, `MainWindow.swift`, `ProjectsPage.swift`; source reviewed |
| Main error / project editor error alerts | OK | Native; no custom header | Unchanged | `MainWindow.swift`, `ProjectsPage.swift`; source reviewed |
| Choose folder popup (`NSOpenPanel`) | Native file navigation and dialog actions | System controls | Unchanged | `ProjectsPage.swift`; source reviewed |
| Desktop selection overlay | Target label; no header controls | No header controls | Unchanged | Native helper; 23, 24, 25 |
| System menu bar / app commands | App menus; pencil status item and queue count | Native | Unchanged | `AnnotatorApp.swift`; `menu-check/` status-item captures |

Update 2026-10-14: the menu now follows Operator's panel. Its header holds the
title and one glass ⋯ menu (Open Annotator, Settings…, server, permissions, agent
prompt, Quit). It has no Annotate screen button, footer or Projects button. The
comment microphone and Submit are footer actions. These retain their existing styles and behavior.

## DesignKit API and behavior

Two new files provide `KitToolbarPicker(selection:options:)` and
`KitHeaderSearchField(text:prompt:onClose:)`. `DESIGN.md` documents their placement,
API and the rule for all header controls. `Controls.swift`, `Sidebar.swift` and
`Shell.swift` were not edited.

The picker keeps the existing native `Menu` and ordered buttons, selected
checkmark, values, titles and binding. Options remain General, Dictation and Conn.
The search field opens focused, preserves Command-F, and clears/closes on Escape.
Existing action closures, explicit accessibility labels, help strings, disabled
conditions and keyboard shortcuts stay intact. Save still shows Saved for 1.6 s.
Heroicons and the neutral theme remain in use. Neither app nor menu-bar icons changed.

## Verification

- Debug and Apple Development release bundles built successfully.
- `scripts/test.sh`: 30 Swift helper tests, 87 Rust tests and 16 Swift bridge /
  dictation tests passed. One existing Rust test remains ignored.
- `scripts/smoke-core.py`: passed settings, permissions, hotkeys, project CRUD,
  priority, routing, capture-to-submit, screenshot, live queue, offline retry,
  deletion, malformed commands and EOF shutdown.
- `scripts/snapshots.sh`: 88 PNGs before and 88 after, including 44 light/dark
  pairs per phase. App windows use ScreenCaptureKit, not offscreen renders.
  Three pairs per phase are the existing native overlay drawing fixtures.
- `scripts/check-menu.sh`: passed both appearances, intrinsic 360 × 520 sizing,
  empty/overflow states, recent-item navigation and reopening the main window.
  The first run hit ScreenCaptureKit error -3811 at `dark-menu-offline`; a full
  rerun passed. The four status-item images use the existing native-view capture.
- `scripts/check-dictation.sh`: passed with real focus checks enabled. Frontmost
  PID, key editable field, missing-paste recovery, typing, responder paste and
  Escape passed. This uses a fake API and records no audio.
- `codesign --verify --deep --strict`: passed. App, core and capture helper each
  have an exact designated-requirement match to the archived 52187d6 delivery.
  `/Applications/Annotator.app` does not exist in this VM, so the original delivery
  ZIP supplied the reference binaries. Bundle ID remains `com.nckrtl.annotator`;
  identity is `Apple Development: Nick Retel (G9Y9TT23QF)`.
- `git diff --check`: passed in both repositories.

All captured header pairs were reviewed in `before-review-1…4.jpg` and
`after-review-1…4.jpg`, with full-size checks of the narrow filtered search and
Dictation layouts. The controls have the same 30 pt capsule height, neutral glass,
short separators and text/icon alignment as the existing Projects toolbar.
No clipping or overlap was found in the changed headers at the 900 × 560 minimum
content size. Search text has less room when Back and +/… are present, but its
placeholder, caret and close control remain visible. Sheet and popup headers fit
at their existing fixed sizes.

Computer Use's Accessibility/Screen Recording permissions were pending, so a
manual mouse/keyboard/VoiceOver pass on the new header picker could not run.
Keyboard and accessibility preservation were reviewed in source; they are not
claimed as an end-to-end interaction test. Native confirmation/error dialogs and
the system folder chooser were source-reviewed, not captured open. Real Operator
audio, full-screen capture and multiple-display interaction were not retested.

Screenshots: `apps/mac/Snapshots/glass-headers/`, also copied to the shared delivery
folder at `/Volumes/My Shared Files/Agent/annotator/glass-headers/screenshots/`.
The shared `REPORT.md` records the final Annotator head, ZIP path and SHA-256.
Build/test logs and signature comparisons are beside it in `logs/`.

## Same issues found in other apps (not changed)

Read-only source sweep at Vault `4009920` and Operator `519369e`:

| App / header | Non-glass control | Source |
| --- | --- | --- |
| Vault: Password health | Bordered `KitPicker` filter | `Vault/VaultPages.swift:65` |
| Vault: Trash | Boxed `KitSearchField` in page header | `Vault/VaultPages.swift:49` |
| Vault: collection search | Plain header search field and close button | `Vault/ItemListColumn.swift:26` |
| Vault: sidebar top bar | Plain sync and lock `KitIconButton`s | `Vault/VaultWindow.swift:54`, `:60` |
| Operator: Transcriptions search | Plain header search field and close button | `mac/app/App/Pages.swift:132` |

Operator's menu panel also uses a native `.tabs` History picker at
`mac/app/App/Panels/MenuBarPanelController.swift:221`, outside a DesignKit toolbar
group. It is not the bordered `KitPicker` defect; its native glass appearance was
not verified here. Operator's Dictionary picker and settings pickers are form-row
controls, not header defects.
