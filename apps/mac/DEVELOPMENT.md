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

## Accent color

Settings → Theme → Accent color offers neutral, cobalt, teal, orange and violet, plus a
custom hex field, saturation/brightness square and hue strip. The choice updates controls
immediately and persists in this app’s local defaults (`designkit.accent`). Original restores
the app’s default theme. It does not change system appearance or another app’s preferences.

Requires DesignKit `7186ab3` or later in the sibling `design-kit` checkout.
