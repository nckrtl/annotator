# Annotator icons — 2026-10-14

The comment and permission panels and both detail empty states now use
DesignKit’s supplied Annotator mark through `KitBrandMark(.annotator)`.
Removed the hand-drawn pencil tile. The menu bar already uses the supplied
idle and active assets through `KitBrandImages.menuBarIcon`.

Regenerated every file in `src-tauri/icons` with DesignKit’s unchanged
`BrandExport` and `iconutil`. The app icon now carries the supplied mark;
the old blue pencil is gone. Generic edit icons remain action symbols.

Implementation and checks ran in VMPal’s `nick-vm`, in the isolated
`annotator-brand-mark-20261014` worktree, from `5fd10b5d5`.
DesignKit: `7afb9116`.

- Swift app tests passed (16 tests).
- Debug bundle build and identity/signature checks passed.
- The packaged `Annotator.icns` exactly matches the generated source file.
- `git diff --check` passed.
- Inspected the app icon and both appearances of the comment, permission,
  annotation empty detail and project empty detail views.

ScreenCaptureKit failed with error `-3811`; the UI captures use AppKit’s
offscreen rasterization. They verify the mark and layout, not WindowServer
composition or focus. No installed app was changed and no server restarted.

Logs and all 76 offscreen captures:
`/Volumes/My Shared Files/Agent/annotator/icon-audit-20261014/evidence`.
