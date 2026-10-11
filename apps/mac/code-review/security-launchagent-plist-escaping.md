# The headless LaunchAgent plist does not escape its values

- Severity: suggestion
- Area: security
- Location: `scripts/t3-headless.sh:52`

## What is wrong

`install` writes `~/Library/LaunchAgents/com.nckrtl.t3-headless.plist` with an unquoted heredoc. `$executable`, `$cache`, `$script`, `$home`, `$port`, and `$PATH` are inserted as XML text. Nothing escapes `&`, `<`, or `>`.

`PATH` is whatever the shell had when install ran. The agent is `RunAtLoad` and `KeepAlive`, so that `PATH` is the server's `PATH` on every login. The comment says this is so the server can find `codex` and `claude`. Those tools are then looked up on a `PATH` captured once, including any directory that happened to be in front.

`T3_HEADLESS_HOME` and `T3_APP` are also expanded into the plist. A value that contains XML markup changes the plist structure. `launchctl` will reject a broken plist. A carefully built value can add keys.

## Why it matters

The job outlives the shell that installed it. A `PATH` with an unexpected directory in front becomes the permanent search path for every CLI the headless server starts. An unescaped `&` in a path makes the agent fail to load, or loads a different document than the script printed.

## What to change

Build the plist with `PlistBuddy` or a plist encoder so values are escaped. Set `PATH` to a fixed list (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`) plus directories the user named on purpose. Reject home and app paths that contain characters a path cannot need.
