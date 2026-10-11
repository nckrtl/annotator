# Code review

Whole-repository review of Annotator, with weight on security and performance. Each finding is its own file. Line numbers refer to the tree at review time.

I would not approve this tree until the security bugs below are fixed. The capture, Ofide, and DevTools paths can send screen contents or tokens to a host the user did not mean, and an idle Conn session starts in `full-access` when a new annotation arrives. The hover path and the live queue will also stall once real screenshots and web apps are in use.

Things that already look sound are in [approvals.md](approvals.md).

## Security

| Severity | Finding |
| --- | --- |
| bug | [Capture and Ofide URLs are not pinned to the host the user sees](security-capture-url-not-pinned.md) |
| bug | [DevTools trusts every listening port and the page's own reply](security-devtools-untrusted-endpoint.md) |
| bug | [New annotations auto-start a full-access agent](security-agent-nudge-full-access.md) |
| bug | [Text fields and DOM HTML are stored and posted with no secret check](security-sensitive-text-capture.md) |
| bug | [Delete puts the server's id straight into the URL path](security-delete-id-path.md) |
| bug | [Copy Pairing URL executes whatever binary the runtime file names](security-pairing-executes-runtime-argv.md) |
| suggestion | [Agent prompts interpolate names and paths into shell and jq](security-agent-prompt-interpolation.md) |
| suggestion | [The headless LaunchAgent plist does not escape its values](security-launchagent-plist-escaping.md) |

## Performance

| Severity | Finding |
| --- | --- |
| bug | [Every hover over web content opens DevTools and runs JavaScript](performance-devtools-on-every-hover.md) |
| bug | [The live queue downloads and keeps every screenshot](performance-queue-downloads-screenshots.md) |
| bug | [Every queue change spawns a Node status process](performance-server-status-on-every-event.md) |
| suggestion | [Counting pending files reads every screenshot into memory](performance-pending-counts-read-screenshot-files.md) |
| suggestion | [Hover walks a large accessibility subtree on one serial queue](performance-ax-walk-on-hover.md) |
| suggestion | [Each client builds a new URLSession and never invalidates it](performance-new-urlsession-per-request.md) |
