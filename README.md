# Annotator

Point at something on screen, say what to change, and hand it to a coding agent. Each comment becomes a task in a local queue that agents claim, complete, and mark done.

This repository holds two parts:

- [`packages/annotator`](packages/annotator): the npm package [`@nckrtl/annotator`](https://www.npmjs.com/package/@nckrtl/annotator). A browser toolbar for annotations with voice input, and the local task server. Read its [README](packages/annotator/README.md).
- [`apps/mac`](apps/mac): Annotator for macOS, a free menu bar app. Press a hotkey, click any element of any app, and comment. It posts the comment, a screenshot, and the element's accessibility details to the same task server. Read [DEVELOPMENT.md](apps/mac/DEVELOPMENT.md).

## Development

The root is a bun workspace with one lockfile for both parts.

```sh
bun install
bun run check && bun run build && bun run test   # the npm package
bun run mac:test                                 # the Mac app: Swift, Rust and view tests
```

[AGENTS.md](AGENTS.md) describes the layout, the checks, and the release rules.

## License

[MIT](LICENSE)
