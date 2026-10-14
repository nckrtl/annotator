# Conn session compatibility — 2026-10-14

The failure is an API removal, not a new activity or message enum.

Conn merge [`fa520cee50b55c6f78833d8f13123f33346bdf72`](https://github.com/nckrtl/conn/commit/fa520cee50b55c6f78833d8f13123f33346bdf72)
(October 12, upstream v0.0.46-preview.20261010.2909) removes the V1
snapshot and dispatch endpoints. Its first parent, `1371bddf1ba6a27b7861673151eb967e81a6a8f4`, still has both.
The removal is in `packages/contracts/src/environmentHttp.ts`. Later merges
`6c4736c2bd` and `c1566e83fb` retain V2. The investigated main head was
`068a2263aa0614b25ae3f75d46fb774414849a45`.

`GET /api/orchestration/snapshot` now falls through to the static handler in
`apps/server/src/http.ts`. With the desktop web assets present, it returns
`index.html` with status 200. Annotator treated that body as a `Snapshot` and
replaced the JSON syntax error with the misleading “unexpected shape” alert.
No required JSON field or enum can repair that response. This conclusion comes
from the server source; Nick's running server and data were not inspected.

The associated contract changes are:

- Read `GET /api/orchestration/shell`, with `x-t3-orchestration-protocol: 2`.
  Project `id` and `workspaceRoot` remain strings. Model selection still uses
  `instanceId` and `model`; it also accepts historical `provider`. Thread dates
  and deletion markers are non-essential hints, not reasons to reject a snapshot.
- Thread reads still use `/api/orchestration/threads/:id`, but require that header.
  The body changed from `{thread: ...}` to `{projection: {thread: ..., runs: ...}}`.
  The old required `thread` field is absent. V2 replaces `session.activeTurnId`
  with run state for the idle check. Missing or unknown activity is not idle.
- `POST /api/orchestration/dispatch` was removed. Projects now use
  `POST /api/projects/mutate`. Thread commands use Effect JSON RPC
  `orchestration.dispatchCommand` at `/ws?orchestrationProtocol=2`.
- `thread.create` retains its model, runtime, interaction and workspace fields;
  V2 assigns timestamps. Both thread creation and message dispatch require
  `createdBy: "user"` and `creationSource: "web"`, as used by Conn’s desktop client. `thread.turn.start` became `message.dispatch`:
  `message.messageId`, `message.text` and `message.attachments` move to top level,
  and `dispatchMode: {type: "start_immediately"}` is required. The old role,
  runtime, interaction and timestamp fields are not sent with that message.

See `packages/contracts/src/{environment.ts,orchestrationV2.ts,project.ts,modelSelection.ts}`
and `apps/server/src/{orchestration-v2/http.ts,ws.ts,auth/EnvironmentAuth.ts}`
in that Conn revision. WebSocket authentication accepts the same bearer token
as HTTP; it does not require a new Keychain item.

Annotator now reads the public environment descriptor once per client to choose
V1 or V2 and obtain `serverVersion`. It retains V1 support. It never retries a
mutation under another protocol. Both transports require a sequence acknowledgement;
an HTML page or a broken RPC reply cannot count as a successful session.
WebSocket operations have a 15-second deadline and do not follow redirects.

The read models omit titles, message bodies, activities, provider details and
other unused fields. Optional model hints tolerate missing or changed shapes.
Unknown activity states map to `Unknown` and prevent automatic follow-ups.
Required fields have errors with their paths and the server version when available.
A genuinely new protocol version is rejected before writes; additive read-model
changes within the supported protocols do not require an Annotator update.

Connection saving still validates and normalizes the endpoint before using it
as a Keychain account. Reads use that endpoint, with the existing home-key migration
only for the fixed local endpoint. Session ownership remains tied to the selected
endpoint. Conn still writes integer `pid` and string `origin` in
`server-runtime.json`. Its desktop activation protocol remains version 1, with
the same `open-thread` fields and SHA-256 socket path. The desktop socket,
runtime and environment-id lookup only run when
opening the Conn window or pairing; session creation does not need them.
These paths were reviewed without reading any real token, runtime file or user data.

Fixtures under `src-tauri/fixtures/conn` contain only invented projects, IDs and
messages, based on the V1 and V2 contracts. They cover old, current and future
snapshots and thread responses. Loopback tests exercise authenticated HTTP,
Effect WebSocket requests and keepalives, project creation, thread creation,
initial annotation dispatch, session persistence, thread reads, follow-up dispatch,
rejection, missing acknowledgements, malformed required fields and unknown states.
They do not use the Keychain.

A real Conn server could not run from the dependency-free clone: Node 24 reported
`ERR_MODULE_NOT_FOUND` for `@effect/platform-node` at `apps/server/src/binCli.ts`.
No dependencies were installed in the clone. The VM's Conn Dev bundle contains
an Electron development launcher, not a bundled server. Real Conn schema execution,
provider execution and desktop window opening remain unverified. Nick's real
Conn Dev was not contacted.


Verification on the VM:

- `scripts/test.sh`: 30 Swift helper tests, 96 Rust tests (one existing ignored
  local-server lifecycle test), and 16 Swift app/core tests passed.
  The ignored lifecycle test was then enabled explicitly and also passed.
- `scripts/smoke-core.py`: passed for both the debug core and the signed release
  core, with a temporary home, fixture helper and loopback annotation server.
- `scripts/check-menu.sh`: light/dark menu sizing and navigation passed.
- `scripts/check-dictation.sh`: focused panel, responder paste, missing-paste
  recovery, typing and Escape passed with a fake API. No audio was recorded.
- Projects and the missing-`workspaceRoot` error were captured in light and dark
  with ScreenCaptureKit using only demo data. To repeat, build the debug bundle
  and launch it with `ANNOTATOR_UI_DEMO=1`, `ANNOTATOR_UI_CONN_CHECK=1` and
  `ANNOTATOR_UI_SNAPSHOTS=<output-directory>`.

The new Conn tests include the complete V1 session flow and the V2 HTTP/WebSocket
flow. They verify saved session IDs and command acknowledgements. This is an
isolated protocol smoke test, not an end-to-end test against a real Conn server.


The release bundle passed deep/strict code-signature verification. The designated
requirements of the app, Rust core and nested capture helper were compared directly
with their binaries extracted from `Annotator-4d72a1a-appledev.zip`: all three
matched exactly. The identity remains Apple Development: Nick Retel (G9Y9TT23QF),
and the main bundle ID remains `com.nckrtl.annotator`.
