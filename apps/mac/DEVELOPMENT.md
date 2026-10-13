# Development

```sh
bun install
scripts/test.sh       # every test suite
scripts/install.sh    # build, sign, install and start /Applications/Annotator.app
```

Each install replaces the running app. The annotation server keeps running.
The permission grants stay, because the bundle id and signing identity stay
the same.

## Layout previews

`bun run dev` serves the React views on port 1430. Open
`http://127.0.0.1:1430/preview.html?window=menu` to see one window with sample
data and a mocked Rust side. Other windows: `comment`, `settings`,
`onboarding`, `detail-id-215`. Vite reloads the page on save.

## Where things are

- React views: `src/`. Shared look: `src/ui.tsx` and `src/ui.css`, copied from
  Ofide. Do not edit them here; change them in Ofide and copy them over.
- Rust core: `src-tauri/src/`. One module per area (`queue.rs`, `conn.rs`,
  `ofide.rs`, …); `app.rs` wires them and builds the `state` the views show.
- Swift helper: `native/`. Overlay, hit test, capture and DevTools lookup.
- The contract between the parts: `docs/port.md`.

## Logs

```sh
tail -f ~/Library/Logs/Annotator/annotator.log
```

The helper's output and errors go to the same log.
