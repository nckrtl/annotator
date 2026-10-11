# Live development

Run from this checkout:

```sh
scripts/dev.sh
```

This builds and signs a Debug app, starts InjectionNext, and restarts only this
checkout's Annotator. Save any open comment first. The annotation server keeps
running. Once started, edit a SwiftUI view and save it; Inject refreshes the
open view after InjectionNext compiles the changed file.

The comment panel, settings, projects, onboarding, and annotation detail views
observe injection. Function-body edits, colours, spacing, and text are suitable
for live reload. Adding stored properties, changing signatures, or adding files
requires another `scripts/dev.sh` run. Existing initializers and startup code
do not run again just because their source changed. AppKit window setup may
need the window reopened. State is preserved where SwiftUI can retain identity.

## Setup

Install [InjectionNext 2.0.1](https://github.com/johnno1962/InjectionNext/releases/tag/2.0.1)
in `/Applications/InjectionNext.app`. The package pins Inject 1.6.0.
Use the full Xcode installation selected by `xcode-select`.

The dev build uses `xcodebuild` directly on `Package.swift`. No Xcode project or
open Xcode window is needed. Compiler logs live in `build/InjectionDerivedData`;
keep them while the app is running. Do not enable InjectionNext's compiler
interception or launch Xcode through it for this workflow.

The app keeps its bundle ID, path, and signing identity so existing permission
grants can remain valid. Only the dev entitlement file disables library
validation, which InjectionNext needs to load locally compiled code.

## Logs and release builds

```sh
tail -f build/dev.log build/injection.log
```

Build failures are printed by the script and saved in `build/dev-build.log`.
Injection errors appear in the runtime logs. A failed injection leaves the old
code running; fix the error and save the file again.

`scripts/bundle.sh debug` builds without restarting. `scripts/bundle.sh`
builds the normal signed release app with the original entitlements. Inject's
view hooks are no-ops in release builds, and the injection bundle is not loaded.
Relaunch after switching between dev and release builds.

## Cancelling dictation

Cancel closes the comment panel immediately and sends `POST /dictate/cancel`
to Ofide in the background. It never calls the stop-and-paste endpoint.
The configured Ofide build must support this endpoint. The installed Ofide Dev
build does. `/status.cancelledAt` lets Annotator also close the panel when
Ofide handles Escape. New recordings wait for the previous cancellation.

`swift test` includes panel tests with a delayed Ofide response. They verify
that cancellation closes synchronously while recording and transcribing.
