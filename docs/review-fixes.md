# Review verification — 2026-10-14

Initially verified the supplied report against `abdf31c64`. Read the root guides,
the package README, the Mac guides and the native process contract. All twelve
findings led to a fix or cleanup. Some descriptions refer to older code.

Transferred all 36 changed files without loss to `annotator-review-fixes`, based
on `origin/main` at `f6e66fe951c5c6af14a0a7af188c559b9636097f`. The current
verification below ran in the VMPal macOS VM. The host checkout stayed clean on main.

1. **Browser access: confirmed.** The server allowed wildcard CORS and private-network
   access by default and did not validate Host. Browser origins now require an explicit
   `--allow-origin` entry, except for the server's own origin. Unexpected Host headers
   are rejected before routing. Originless agents remain supported. The Mac startup
   uses this secure default. Browser restrictions vary, so the report's claim that
   every public page can exploit this in every browser is too broad.

2. **Vite queries and verification overhead: confirmed.** Routing now matches the
   URL pathname and forwards the query. Identity probes use `/health`. Mutations and
   event subscriptions no longer fetch the annotation database before forwarding.

3. **Shortcut recording: confirmed.** Recording now ends on section changes,
   clicks, app deactivation and view disappearance. Plain typing ends recording
   and passes through. Only Escape and a valid shortcut are consumed.

4. **Typed comments after dictation failure: confirmed.** An idle, previously failed
   recording no longer blocks an explicit Submit. Failures during an active finish
   still block that attempt. Task cancellation remains enforced.

5. **Scrolled browser targets: confirmed.** Records now preserve exact horizontal
   and vertical scroll offsets. Target lookup and editing convert the recorded box
   to current viewport coordinates. Older records use their saved vertical scroll.
   Fixed elements keep viewport coordinates. Edited records save the new offsets.

6. **Frozen-overlay paths: confirmed as obsolete code.** Releasing the overlay at
   selection is intentional and documented. Removed `clickWhileFrozen`, `resume`,
   `selectAt`, the comment-moving state and their host/core protocol branches.
   Selection still ends before capture. The overlay is not restored after Submit.

7. **Corrupt records: confirmed in part.** Invalid files could stop store startup
   and operations that list records. The watcher already caught exceptions, so
   the reported watcher crash was outdated. Invalid records are now logged and
   preserved while valid records remain available. A transient parse failure does
   not create a deletion marker. Creating work with an unreadable ID cannot
   overwrite its file. Transition journals and store metadata still fail loudly
   when corrupt; this change covers annotation files, not recovery metadata.

8. **Electron accessibility startup: confirmed.** A PID is cached only after
   `AXManualAccessibility` succeeds. Initial selection retries briefly off the main
   thread while the tree appears. Hover does not wait. Retry scheduling is limited
   to eight reads and 350 ms, in addition to the existing AX call timeouts. Window
   fallback remains available when no web area appears.

9. **Finished counts: confirmed.** Projects and the annotation collection now use
   the same open-status predicate. Cancelled records count as finished.

10. **Body accumulation: confirmed.** Request bodies use buffers and a running byte
    count, then decode once. Tests cover split UTF-8 characters and the 10 MiB limit.

11. **Operator stop state: confirmed, with a concurrency constraint.** A completed
    stop suppresses redundant cancel requests. Failed stops still permit cleanup.
    Cancel can interrupt a stop in flight, and a late stop cannot clear the state
    of a newer recording.

12. **Service verification: confirmed in part.** `/health` now identifies the service.
    CLI lifecycle checks and the Vite bridge use it. The Mac availability probe also
    uses health. The native annotation client reads records for queue display and
    screenshot retrieval; its `meta.service` validation remains necessary. The
    reported four identical verification implementations do not exist in this checkout.

## VM verification

- Frozen install, package check and build: passed with Bun 1.4.3 and Node 24.
  The documented Bun version is 1.4.2. The lockfile did not change.
- Package tests: passed, including 27 unit tests and all nine integration scripts.
- Mac `scripts/test.sh`: passed. 33 Swift helper tests, 77 Rust tests,
  18 Swift core tests and three shortcut-recorder tests. One existing Rust test is
  ignored. The optional snapshot test returns without rendering unless configured.
- Mac core smoke test: passed with temporary data and a controlled helper.
  Build the debug core first and set `CARGO_TARGET_DIR` when using an alternate
  build directory.
- Signed Release `scripts/build-app.sh`: passed with
  `Apple Development: Nick Retel (G9Y9TT23QF)`. App and helper identities and
  signatures passed the build script's checks.
- DesignKit dependency: clean pinned checkout at
  `f5da896674535301d5cc59a0c14babed7b554a2c`.
- Optional offscreen snapshot test: passed. Inspected General, Dictation and
  Projects with a cancelled record in light and dark. The obsolete Conn settings
  capture was removed. These captures verify layout and the finished count,
  not active control colors, desktop focus or WindowServer composition.
- `git diff --check`: passed.

Two existing watchdog tests initially failed because they used short sleeps to
assume callback delivery and renewal before expiration. The release check now
waits up to one second for the callback. The renewal test renews synchronously
before yielding and separately checks disarming. The focused suite and full
native suite passed after these test changes; production deadlines are unchanged.
The first smoke commands lacked a built debug executable; the smoke check passed
after building it and selecting its Cargo target directory.

Real Electron capture and Operator audio/paste were not exercised on the installed
app. No app was installed, no existing server was restarted, and no release was
published. The new browser policy takes effect when the updated server starts.
Direct browser integrations must configure `--allow-origin` or use the Vite bridge.

To repeat the offscreen captures without taking desktop focus, run from `apps/mac`:

```sh
ANNOTATOR_REVIEW_SNAPSHOTS="$PWD/build/review-snapshots" \
  swift test --package-path app --scratch-path build/swift-app \
  --filter renderReviewedScreensWithoutTakingFocus
```
