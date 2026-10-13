# Annotator monorepo

Two parts share this repository. Each has its own guide; read it before you change that part.

## Layout

- `packages/annotator`: the npm package `@nckrtl/annotator` (TypeScript, Vite+). Guide: its `README.md`.
- `apps/mac`: Annotator for macOS (Tauri 2, React, a Rust core and a Swift helper). Guide: `apps/mac/AGENTS.md` and `apps/mac/DEVELOPMENT.md`. Its `package.json` name is `annotator` and stays private.
- `package.json`: the bun workspace root. One `bun.lock` covers both parts. Bun 1.4.2.
- `.github/workflows`: `ci.yml` tests both parts; `release.yml` publishes the npm package.

The Mac app talks to the package's server only over HTTP. Do not import code from one part into the other.

`LICENSE` is at the root, and `packages/annotator/LICENSE` is a copy for npm. Keep them identical.

## Checks

The package, from `packages/annotator` (the root `check`, `build` and `test` scripts run the same):

```sh
bun install --frozen-lockfile
bun run check
bun run build
bunx playwright install chromium   # once
bun run test
```

The Mac app, from `apps/mac`:

```sh
bun run build                 # tsc -b and vite build
scripts/test.sh               # swift test, cargo test, tsc and bun test
bun run tauri build --debug   # an unsigned debug app; needs scripts/build-native.sh first
```

`scripts/install.sh` signs with the user's identity and installs into `/Applications`. Run it only on the user's Mac, and only when they ask.

## Releases

- npm: push a tag `v<version>` that matches `packages/annotator/package.json`. `release.yml` checks the tag, tests, and publishes with npm trusted publishing (OIDC). npm binds that trust to this repository and to the file name `.github/workflows/release.yml`. Do not rename or move it.
- Mac app: there is no release workflow yet. Its releases will use tags like `mac-v0.1.0`, which do not match the npm trigger `v*`.
- Do not bump versions, create tags, or publish unless the user asks.

## Writing

Write docs, comments and UI text in plain, brief English: short sentences, active voice.
