# @nckrtl/annotator

Browser annotations with voice input and a local task server for coding agents. Requires Node.js 22 or newer for the CLI.

Install the toolbar in your development project:

```sh
npm install --save-dev @nckrtl/annotator
```

Mount it once from your browser entry point:

```ts
import { mountAnnotation } from "@nckrtl/annotator";

const annotator = mountAnnotation();
// Call annotator.destroy() when tearing down the host application.
```

Start the local server with `npx @nckrtl/annotator serve`, then open the toolbar settings, choose **Local server**, paste the printed URL, and save. A host can pass the URL instead: `mountAnnotation({ serverUrl: "http://127.0.0.1:29703/annotations" })`.

## Options

| Option              | Purpose                                                                                                                                                                                                                         |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `serverUrl`         | Local annotation server endpoint.                                                                                                                                                                                               |
| `transports`        | Extra delivery modes; see [Transports](#transports).                                                                                                                                                                            |
| `delivery`          | Delivery mode for a tab without a saved choice: `"server"` or a transport id. Default: `"server"` when `serverUrl` is set, otherwise the first transport.                                                                       |
| `metadata`          | `({ element, url, pathname }) => Record<string, unknown>`. Extra context stored as `metadata` on each new annotation and sent with it, such as a host session id.                                                               |
| `capture`           | `(rect) => Promise<Blob \| string>`. Supplies screenshot pixels for the viewport area `rect` (CSS pixels), for example from Electron or the Chrome DevTools Protocol. When it is missing or fails, the overlay renders the DOM. |
| `dictation`         | Speech input; see [Dictation](#dictation).                                                                                                                                                                                      |
| `floatingControl`   | `false` hides the floating pill; see [Host toolbar integration](#host-toolbar-integration).                                                                                                                                     |
| `discoverServerUrl` | Endpoint to probe when nothing is configured. `inject.js` sets it to the `annotations` URL next to its own URL.                                                                                                                 |
| `getToolbarData`    | Optional request context shown with the annotation.                                                                                                                                                                             |

## Screenshots

Each annotation carries a JPEG of the area around the element. The overlay takes it after the comment popup opens and the dictation trigger is sent, when the browser is idle, and attaches it when it is ready. The DOM render clones only the part of the page that can reach the crop and reuses cached fonts and images. A host with real pixels passes `capture`.

## Dictation

`dictation: { provider: "post", postUrl, stopUrl }` asks a desktop dictation app to record and type into the comment field: the overlay sends `POST postUrl` when the popup opens and `POST stopUrl` to stop. `dictation: { wsUrl }` streams microphone audio to a Diction-compatible WebSocket and inserts the transcript. `autoStart: false` waits for the microphone button.

## Local annotation server

Run `npx @nckrtl/annotator serve` and choose **Local server** in **Delivery mode**, and paste the printed annotation URL into **Annotation server URL** in the toolbar settings. The URL is remembered for the tab across refreshes. A failed submission can be retried manually while cached; it never falls back to another delivery mode. In server mode, the next successful list removes cached records not present on the server.

The server binds to `127.0.0.1` on a random available port. Use `--port 29703` for a fixed port. Use `--host` without an IP to bind to `0.0.0.0`; the printed URL then uses the machine's first network address. Each server has a separate port and store. The URL is `http://127.0.0.1:<port>/annotations`. Local-network browser permission may be required. On mobile, loopback refers to the phone, not the development machine.

To run the server in the background, use `npx @nckrtl/annotator start --state storage/annotator.json`. It returns when the server answers and prints the state as JSON: PID, port, URL, skill URL, and store. `status --state FILE` reports whether that server runs and removes a state file left by a crashed server. `stop --state FILE` stops it with SIGTERM, so the store closes cleanly; it never signals a process that does not answer as the annotation server. Output goes to a `.log` file next to the state file. `serve --state FILE` writes the same file for a foreground server.

By default, annotations are saved in a new temporary directory printed at startup. To resume them later, run `npx @nckrtl/annotator serve --store /path/to/session`. If the port changes after restarting, paste the new URL into settings.

Each annotation has one JSON file. Its directory matches its state:

```text
/tmp/annotate-XXXXXX/
  todo/<id>.json
  in-progress/<id>.json
  done/<id>.json
```

The server also prints a **Skill URL** at startup: `http://127.0.0.1:<port>/skill`. Give this URL to an LLM to load a short Markdown skill with the running server’s annotation URL and instructions to watch for annotations, claim them, and complete or release them. The skill does not set up the server or the browser settings; the user does that. `GET /annotations` advertises it as `meta.skillUrl`; the development bridge also serves it. Reading the skill does not claim or change work.

Use the printed URL as `$ANNOTATIONS_URL`. A monitor claims work, then completes or releases it:

```sh
curl -X POST "$ANNOTATIONS_URL/claim"
curl -X POST "$ANNOTATIONS_URL/complete" \
  -H 'Content-Type: application/json' \
  --data '{"id":"ID","summary":"Updated the button and verified it."}'
curl -X POST "$ANNOTATIONS_URL/release" \
  -H 'Content-Type: application/json' --data '{"id":"ID"}'
curl "$ANNOTATIONS_URL"
curl -N "$ANNOTATIONS_URL/events"
```

`POST /claim`, `/complete`, and `/release` also work at the server root. A bodyless claim takes the oldest non-question todo annotation, moves it into `in-progress/`, and returns `{data: annotation}` with status `in_progress`. It returns `204` when empty. Concurrent monitors receive different annotations. Completion accepts an in-progress ID and optional summary, moves the file into `done/`, and sets status `done`. Repeating completion succeeds without changing the record. Release moves an in-progress annotation back to `todo/` with status `todo`. Invalid transitions return `409`; unknown IDs return `404`.

`GET /annotations` returns `{data: [...]}`, including completed records. `POST /annotations` creates work; repeated IDs return the existing record without resetting it. The existing `POST /annotations/:id/status` endpoint remains available and accepts both `todo`/`done` and the older `pending`/`resolved` names. Cancelled annotations are kept in `done/` with status `cancelled`. The toolbar translates these states to its existing pending, in-progress, and resolved markers.

One server owns a store directory at a time. Claims run without yielding between selecting and moving the file. Writes finish before HTTP acknowledgement. State transitions commit the complete new record to an atomic intent journal before changing directories. After a process stop, the next read recovers that record and removes the old one, keeping question markers and summaries consistent with the transition. A stop before the intent commits leaves the old record unchanged. In-progress work survives restarts and stays claimed until completed or released; there is no automatic lease expiry. Old single-file stores passed to `--store` are migrated, preserving the original as a `.legacy` backup. The server watches the three directories, and file changes trigger browser updates. Write external JSON edits atomically; moving a record between the directories also updates its status when the server reads it.

Local annotations receive a stable `number` from the server. Numbers increase across the store and do not change when work completes or is released. The toolbar keeps the session counter after completion and uses the same numbers on pins. Reusing a store preserves its numbering; a new store starts at 1. The server prints one activity line per creation or status change, such as `#1 created: Fix the heading`, `#1 in progress: Fix the heading`, and `#1 done: Fix the heading`. Repeated submissions and unchanged statuses do not produce duplicate activity lines.

In Local server mode, deleting a pin removes its JSON file and logs `#1 deleted: Fix the heading`. The bin icon removes all annotations from the connected store, including completed work, and logs `All annotations removed`. `DELETE /annotations/{id}` removes one record; `DELETE /annotations` clears the store, and `DELETE /annotations?pathname=/page` removes only the annotations of that page. Hosts call `clearPageAnnotations()` for the page-scoped removal. Connected browsers receive deletion updates, including after reconnect. The sequence counter is preserved. Failed deletions keep the pins visible and show an error so the action can be retried.

The local server does not launch agents or deliver messages. A host that stores annotations elsewhere registers a [transport](#transports).

When the browser runs on a different machine, its loopback address does not reach the server. Use `--host` to bind to all addresses, or `--host <private-IP>` to bind to one private network address. An HTTPS page also requires an HTTPS endpoint for a remote server; a reverse proxy can forward it to the local annotation process. The proxy changes the network path only: annotations remain in the local store.

## Browsers on another machine

For a Vite application, add the package’s `annotationServerProxy()` plugin once. No annotation port or URL belongs in the Vite configuration:

```ts
import { annotationServerProxy } from "@nckrtl/annotator/vite";

export default { plugins: [annotationServerProxy()] };
```

Keep pasting the URL printed by `serve` into the toolbar. The plugin makes loopback URLs refer to the development machine, even when the browser runs elsewhere. Requests and live events use the page’s origin, so HTTPS works without a separate certificate for the annotation server. Random ports work across server restarts after saving the new URL. The bridge verifies that the target is an annotation server before forwarding requests. It is development-only and does not store or deliver tasks.

## Transports

The local server is the built-in delivery mode, `"server"`. A host adds other modes with `transports`. Each one appears in **Delivery mode** under its `label`:

```ts
import { mountAnnotation, type AnnotationTransport } from "@nckrtl/annotator";

const tasks: AnnotationTransport = {
    id: "tasks",
    label: "Task service",
    check: async () => ({ state: "available", reason: "" }),
    submit: async (annotation) => (await post("/api/annotations", annotation)).data,
    list: async () => (await get("/api/annotations")).data,
    retry: async (annotation) => (await post(`/api/annotations/${annotation.id}/retry`)).data,
    subscribe: (refresh) => {
        const stop = onAnnotationEvent(refresh);
        return { stop, live: () => socketConnected() };
    },
    fields: [
        { id: "tasks-queue", label: "Queue", value: () => queue, save: (value) => (queue = value) },
    ],
};

mountAnnotation({ transports: [tasks] });
```

- `submit` stores a new or edited annotation and resolves with the stored record. Records need `id`, `comment`, and a numeric `revision`; a higher revision replaces a lower one. Rejecting fails the delivery, and the popup shows the error message with a retry button.
- `list` returns every record the transport knows. `resolved` and `cancelled` records remove pins.
- `check` is optional and read-only. It runs when settings open, before every write, and before subscribing. While it is not `available`, the mode is disabled in settings and delivery fails with its `reason`.
- `subscribe` is optional. Call `refresh` when records change. While `live()` returns true, the 15-second poll pauses. Hidden tabs never poll.
- `fields` are optional text settings shown while the mode is selected. `save` receives the trimmed value when the user saves.

`checkTransport(id)` runs a check from host code. Transport ids must be unique and must not be `"server"`.

## Host toolbar integration

Pass `floatingControl: false` to `mountAnnotation` to keep the overlay and keyboard
shortcuts while supplying your own toolbar controls. `getAnnotationState` and
`subscribeAnnotationState` expose a framework-independent, stable snapshot for
`useSyncExternalStore` or other UI frameworks. The snapshot includes active mode,
count, delivery mode, connection, removal errors, and the last check per transport.

Use `getAnnotationSettings()` to populate a native settings form and
`saveAnnotationSettings({ mode: "server", serviceUrl: url })` to save it for this
tab. Pass a transport id as `mode` to select that transport. `checkAnnotationServer(url, signal)` validates the local
endpoint; `checkTransport(id)` checks a transport. These APIs share the
floating UI's storage and delivery. `toggleAnnotationMode` and
`clearAllAnnotations` also work with either UI.

Mark a host toolbar container with `data-feedback-toolbar` so clicks inside it
are excluded from annotation targeting. Call the mount handle's `destroy()` when
the host is removed. Only mount one annotation integration per page.

## Serving the overlay and queue agents

`GET /health` returns 200 without reading the annotation store. `GET /inject.js` serves the installed package's `dist/inject.js`; hosts can load the overlay from the same server and version rather than bundle a copy. A reverse proxy can publish the server under a path, for example `/__annotate`.

Pass `--allow-origin ORIGIN` once for each allowed browser origin, for example the site origin and an app scheme such as `app://host`. The allow-list applies to reads, writes, event streams, and DELETE, including preflight requests. Requests from other origins receive 403. Requests without an Origin header remain available to agents. Without the flag, the server keeps wildcard CORS for local use.

A host can call `mountAnnotation({ serverUrl: "/__annotate/annotations" })` or set that option in `window.__AGENT_ANNOTATION__` before loading `inject.js`. Without an explicit server or saved delivery choice, `inject.js` probes the `annotations` URL next to its own URL and uses it only when the response identifies `meta.service` as `@nckrtl/annotator`. In server mode, a successful list is the only source of pins: local records missing from it are removed, even when the server's store was replaced and has no deletion history. Failed reads keep the cached pins.

`GET /skill` keeps the watch instructions. `GET /skill?mode=queue` serves instructions for an orchestrating agent thread: claim until the queue is empty, delegate independent annotations to sub-agents, keep related work together, complete with a summary, and end the turn. It does not run an endless event-stream loop. Refer to annotations by `number` (for example, #3), never by their internal `id`.

When a comment needs clarification, release the claimed annotation with `POST /annotations/release` and `{"id":"CLAIMED_ID","question":true,"summary":"The question for the user"}`, then ask the user in the thread. The record stays `todo` with `question: true` and its summary; live clients and pins show that it needs an answer. A bodyless `POST /annotations/claim` skips questions, so Watch mode never re-sends them. After the user answers, claim that annotation with `{"id":"CLAIMED_ID"}`. An explicit claim accepts any todo annotation, clears the question marker and its summary, and marks it in progress. Plain releases keep their existing behavior.
