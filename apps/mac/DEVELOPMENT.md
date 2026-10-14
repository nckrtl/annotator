# Development

The Mac UI is SwiftUI on the shared DesignKit. See [AGENTS.md](AGENTS.md) for
surface decisions, build requirements and verification limits.

```sh
# Clone the private shared kit beside this repository, if missing.
git clone https://github.com/nckrtl/design-kit ~/apps/design-kit
bun install --frozen-lockfile
scripts/build-app.sh --debug
open build/debug/Annotator.app
scripts/test.sh
scripts/smoke-core.py
scripts/snapshots.sh
```

`DESIGN_KIT_PATH` can override the package path. macOS 26 and Swift 6.2 or newer
are required. The private npm workspace remains named `annotator`.

Only run `scripts/install.sh` on Nick's Mac when asked. It builds a release with
his signing identity, installs it in `/Applications`, and preserves the bundle id.
The debug build stays in this checkout and is signed ad hoc.

The Rust source directory retains its historical name, `src-tauri`; it no longer
depends on Tauri. Its command handlers and events are carried by inherited JSON
pipes. See [docs/port.md](docs/port.md). The npm package and its browser canvas
remain independent.

Debug demo mode uses made-up data and does not start the core or capture helper:

```sh
ANNOTATOR_UI_DEMO=1 build/debug/Annotator.app/Contents/MacOS/Annotator
```

Add `ANNOTATOR_UI_SNAPSHOTS=/absolute/directory` to capture all views and quit.
`scripts/snapshots.sh` builds first and sets both values. Inspect every light/dark
pair before handing back a UI change. Captures use ScreenCaptureKit’s current-process API. Full-screen behavior and
capture of other apps need a signed, permission-granted app.

## Neutral appearance

`bash scripts/check-menu.sh [absolute-output-directory]` checks the menu's own
fitting size, its empty and overflowing states, and navigation after closing the
main window. It captures light and dark
windows at 2× with demo data. It also captures the actual menu-bar item view,
including the count, in idle and annotating states in both appearances. These are
transparent crops of the system-hosted item, not full desktop captures.
It calls navigation directly; it does not replace
clicking the real status item and its actions. The older snapshot runner supplies
a fixed window size and cannot detect a collapsed menu-bar dropdown.

Every app uses DesignKit's fixed neutral appearance: ink primary actions and neutral
selection. Settings has no Theme section or accent picker. Switches are system green
when on; iOS uses the native full size and macOS keeps the compact DesignKit size.
Old stored accent preferences are unused and left in place.

## Icon dependency verification — 2026-10-13

Branch `remove-phosphor`, using DesignKit `949e84f`. Removed the obsolete icon
package pin and updated the bundle documentation. Production icons are unchanged.

`scripts/build-app.sh --debug` passed, including the SwiftUI host, Swift capture
helper, Rust core and deep/strict ad-hoc signature verification. Existing tests
passed: 27 Swift helper tests, 7 Swift app tests, and 84 Rust tests (one existing
ignored test). The app contains the Heroicons catalog and license and no removed
icon package bundle. Logs: `build/remove-phosphor/`.

## Projects

Projects is a regular sidebar item. Its A–Z list shares annotation entry rows and
Vault's 220 pt sidebar, 300 pt list, detail header, and empty state. Use + to add a
project, Edit to rename it or change its folder, routing rules, notes, model, or
runtime mode. The detail menu keeps agent prompts, Conn sessions, routing priority,
and deletion. The list menu keeps the all-annotations and inbox prompts.

View annotations opens that project's filtered list. Its back button returns to
the selected project. ⌘F searches the current collection; arrow keys select rows.
Routing priority remains file order, independent of A–Z display order. Route earlier
and Route later change that priority. Existing annotations retain their captured
project name after a rename, and remain on the server after project deletion.

The demo snapshot runner includes populated and empty project lists, no selection,
selected details, zero counts, add/edit forms, minimum size, and filtered annotations
in light and dark. The core smoke test checks project CRUD, field preservation,
routing priority, and retention of annotations after deleting a project.

To keep verification builds under the ignored build folder, use Swift's
`--scratch-path build/swift-app` (or `build/swift-native`) and
`CARGO_TARGET_DIR="$PWD/build/rust"`. The smoke test accepts that Cargo target path;
set `TMPDIR` to a directory under `build` for its isolated fixtures.

The menu-bar label uses `pencil.tip.crop.circle` when idle and
`pencil.tip.crop.circle.fill` while annotating, with the open queue count beside it.
These native SF Symbols are Nick's requested exception to Heroicons in the app UI.
