# DesignKit verification — 2026-10-13

Verified on nick-vm, on Annotator branch `designkit`.
Shared DesignKit revision: `4e7a95ca1dfa6b3463888d8203ee528c70c5e513`.
No DesignKit changes were needed.

## Result

Library, detail, Settings, Projects, project editor, menu, comment panel,
permissions and screenshot viewer use SwiftUI and shared DesignKit controls.
The capture overlay keeps its AppKit renderer, with neutral outlines and a
contrasting halo. Every notice is inside a KitGroup; only its icon has a tone.
The Rust core, capture helper, HTTP contract and saved data locations remain.
The npm package source is unchanged. Surface decisions are in ../AGENTS.md.

## Checks

- Frozen Bun install; npm check, build and browser/server tests passed.
- Capture helper: 27 Swift tests passed.
- Rust core: 84 tests passed; one existing test is ignored.
- Swift core: seven tests passed, including dictation start/finish/cancel races,
  missing paste, Unicode pipe framing and project/navigation name collisions.
- Core integration smoke passed against the real npm HTTP server in a temporary
  home: settings, permission/hotkey events, routing, capture-to-submit,
  screenshot retrieval, live queue, offline retry, deletion, invalid commands
  and EOF shutdown. Capture input uses a controlled helper fixture.
- Debug and signed release bundles built. Release uses Nick's Apple Development
  identity, hardened runtime and the original bundle ID. Signing completed
  without a keychain prompt. Deep, strict signature verification passed.
- Install script targets the new release bundle. It was not run on the VM.

## Visual review

54 actual window captures: 27 screens/states in light and dark. Captured with
ScreenCaptureKit's current-process API, using made-up data. Reviewed each pair,
including error/empty states, minimum window size, scrolled settings/editor,
screenshot viewer, menu retry notices and all three overlay modes.

Fixed nested editor scrolling, raw status labels, redundant menu chevrons,
empty-state counts and neutral error groups during review. All controls and
notice text remain readable in both appearances.

Captures on nick-vm:
`/Users/nckrtl/apps/annotator/apps/mac/Snapshots/designkit/`

Names are `light-01-library.png` through `light-27-project-editor-bottom.png`,
and the matching `dark-*` files. The directory is generated and git-ignored.
Regenerate with `scripts/snapshots.sh` from `apps/mac`.

Builds:
- `apps/mac/build/debug/Annotator.app`
- `apps/mac/build/release/Annotator.app`

## Limits

The GUI tool returned “Computer Use was not approved to use Annotator”. Live
click-through, capture of other apps, real Operator paste, multiple displays and
full-screen placement were not verified. The demos validate rendering; core
and fixture tests validate the covered workflows. Comment panels retain the
old all-applications/all-spaces collection behavior.

The app now requires macOS 26, as DesignKit does. Mac CI checks out the private
DesignKit repository and requires a read-only `DESIGN_KIT_TOKEN` repository
secret. That secret is absent, so remote Mac CI is not verified. Local checks
used the VM's authenticated DesignKit checkout.
