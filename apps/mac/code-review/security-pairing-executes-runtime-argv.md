# Copy Pairing URL executes whatever binary the runtime file names

- Severity: bug
- Area: security
- Location: `Sources/Annotator/T3Sessions.swift:209`, `Sources/AnnotatorCore/T3.swift:22`

## What is wrong

`pairingURL()` reads `userdata/server-runtime.json` and takes `pid` and `origin` from it. `runCLI` then loads that pid's argument vector with `sysctl` `KERN_PROCARGS2`. It executes `argv[0]` and, as the script, the first argument that ends in `bin.mjs`.

```swift
process.executableURL = URL(fileURLWithPath: executable)
process.arguments = [script] + arguments
var environment = ProcessInfo.processInfo.environment
environment["ELECTRON_RUN_AS_NODE"] = "1"
process.environment = environment
```

There is no check that the executable lives inside Conn.app or T3 Code.app, that it is signed by the expected identity, or that `server-runtime.json` belongs to the server the user named. The process inherits Annotator's full environment.

`LocalServer` has a smaller version of the same trust. It runs the first executable it finds in this order: `~/.vite-plus/bin/node`, the mise shim, Homebrew, then `/usr/local/bin/node` (`Sources/AnnotatorCore/LocalServer.swift:32`). A file planted at the first path runs when the user starts the annotation server. That one does not copy the environment. The pairing path does.

## Why it matters

`server-runtime.json` sits in the user-writable Conn data folder. A process running as the user can point `pid` at itself, with `argv[0]` set to its own program and one argument ending in `bin.mjs`. The next Copy Pairing URL runs that program and passes through environment variables that were present when Annotator launched. Menu text presents the action as copying a URL.

## What to change

Resolve the Conn executable from a fixed app bundle, or from the path recorded by a server you just authenticated to, and require that path to stay under that bundle. Check the code signature before `Process.run`. Pass a minimal environment (`ELECTRON_RUN_AS_NODE`, `PATH` built from known directories), not `ProcessInfo.processInfo.environment`. For the annotation server, prefer a Node you have already verified, and do not let a home-directory path outrank it silently.
