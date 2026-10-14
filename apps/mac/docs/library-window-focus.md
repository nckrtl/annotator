# Library focus: annotation #229

The main annotations/library window stays hidden on launch. Starting capture
hides it and the flyout. Showing or focusing the comment panel hides the library
before activating Annotator. A LaunchServices reopen during capture or an open
comment does not navigate to the library. Finishing or cancelling does not
restore it. Explicit library/settings navigation and an idle reopen still work.

The comment remains an activating key panel for Operator paste.
The menu-bar label installs the window opener, so explicit navigation works
even when the main window has not been created. Demo snapshots open the library
explicitly.

All edits, builds and checks ran in the VMPal nick-vm worktree. The branch starts
at 8ef04c1 and includes the supplied-brand-mark commit. The host's uncommitted
review fixes were not changed or included.

Validation:
- Debug native bundle built; app/helper identities and signatures passed.
- scripts/check-windows.sh passed in light and dark. It checks hidden startup,
  capture, queue updates, comment activation, frontmost app, key editable field,
  typing, reopen suppression, finish and explicit reopen after close.
- Swift app tests: 16 passed.
- scripts/check-dictation.sh passed with real foreground checks: editable text
  view, missing-paste error, overlay release, typing recovery, responder paste,
  Escape and frontmost Annotator/key editor.
- Initial foreground runs failed during concurrent VM UI activity. Their logs
  are retained. Final window and dictation runs passed without skipping focus.
- Comment images are offscreen renders; window/focus assertions use AppKit.
- git diff --check passed.

Evidence: Agent/annotator/remaining-evidence in the VMPal shared folder.
No installed app was replaced. The existing annotation server was not restarted.
