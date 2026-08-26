# Implementation Plan: editor-session

## Overview

Implement the `editor-session` capability after the completed PNG artifact phase. Neovim Lua will run one loopback HTTP session, serve a vendored plain-JavaScript Quickdraw editor, load the fixed target PNG's embedded snapshot, receive the browser's current snapshot and exported PNG, embed the snapshot with `quickdraw.png`, and atomically save the result. Command/config resolution and Markdown integration remain in the later `neovim-integration` capability.

## Approved Scope

- Vendor `@quickdrawjs/core` 0.2.0 and its license into the plugin; runtime use is offline and requires no npm or build step.
- Use native HTML, CSS, and browser ESM with `createQuickdraw()`.
- Start one server per Neovim process on `127.0.0.1` with an ephemeral port and per-session token.
- Accept one trusted, fixed PNG path from the future Neovim integration layer. Browser requests cannot provide or change it.
- Automatically open the system browser. If opening fails, keep the session alive and expose the URL.
- Allow only one active editor session. Starting another stops the previous session first.
- On save, receive both `store.getSnapshot()` JSON and Quickdraw's exported PNG; Lua embeds the snapshot and writes the resulting PNG.

## Non-goals

- Neovim user commands, config merging, drawing-name/path derivation, Markdown insertion, or cursor-based editing.
- React, Node.js, npm at runtime, a JavaScript build pipeline, CDN assets, or external network requests.
- Multiple simultaneous editor sessions, collaboration, authentication, remote binding, or sidecar files.
- Changes to the approved PNG metadata schema or parser contract.

## Source Evidence

- Quickdraw plain-JS entrypoint and zero-dependency ESM: https://github.com/quickdrawjs/quickdraw/tree/main/packages/core
- Plain-JS example: https://github.com/quickdrawjs/quickdraw/blob/main/examples/vanilla/index.html
- Snapshot persistence: https://github.com/quickdrawjs/quickdraw/blob/main/apps/docs/content/persistence.mdx
- PNG export and `onSave(blob)`: https://github.com/quickdrawjs/quickdraw/blob/main/apps/docs/content/export-images.mdx
- Published package: `https://registry.npmjs.org/@quickdrawjs/core/-/core-0.2.0.tgz`
- npm integrity: `sha512-87v/ZvyX4KYhCWqlR/js8poD6Pf1NuR4IB9RIkNxQ6g5XTUsH5vSePZkoXufVz0PRMFJv1Tmfv7RlqY9U79wMA==`

## Dependency Graph

```text
vendored @quickdrawjs/core 0.2.0
                |
                v
bounded loopback HTTP foundation
                |
                v
blank browser editor vertical slice
                |
                v
fixed-path snapshot load
                |
                v
single multipart snapshot + PNG save
                |
                v
singleton lifecycle + browser verification
```

Tasks remain sequential because Tasks 2-6 repeatedly touch `lua/quickdraw/session.lua`, `web/quickdraw/app.js`, and `tests/quickdraw/session_spec.lua`.

## Architecture Decisions

### Runtime assets

- Vendor the published `@quickdrawjs/core` 0.2.0 package without runtime package installation.
- Record the tarball URL, npm SRI value, MIT license, and a SHA-256 manifest of extracted published files. Verification downloads the tarball, checks SRI, extracts it, regenerates the manifest, and diffs it against the vendored tree.
- Serve checked-in `index.html`, `app.js`, Quickdraw ESM modules, and CSS through the Lua server. No remote scripts, styles, fonts, telemetry, or generated assets are allowed.
- Resolve assets through Neovim's runtime path and an exact route-to-file allowlist. URL paths are not joined to filesystem paths; raw or encoded traversal, backslashes, NULs, and unknown assets are rejected.

### Lua interface

```lua
local info, err = require("quickdraw.session").start({ path = "/absolute/drawing.png" })
local ok, stop_err = require("quickdraw.session").stop()
```

Successful `start()` returns:

```lua
{
  browser_opened = true,
  path = "/absolute/drawing.png",
  url = "http://127.0.0.1:<port>/<token>/",
  warning = nil,
}
```

A browser-launch failure is non-fatal: `info.browser_opened` is `false`, `info.warning.code` is `BROWSER_OPEN_FAILED`, `err` remains `nil`, and the caller can display `info.url`. Preflight, token, bind, or load failure returns `nil, { code, message }` before opening a browser. `stop()` is idempotent and returns `true, nil` unless handle cleanup itself fails.

Session codes are stable: `INVALID_PATH`, `READ_FAILED`, `NOT_QUICKDRAW`, existing `quickdraw.png` validation codes, `TOKEN_FAILED`, `SERVER_FAILED`, `WRITE_FAILED`, and `BROWSER_OPEN_FAILED`. Browser responses never include absolute paths or raw filesystem errors.

### HTTP contract

Every route is under a `/<token>/` prefix. Responses close the connection, use explicit `Content-Length`, and return JSON errors as `{ "error": { "code": "...", "message": "..." } }`.

| Method | Route | Request | Success |
|---|---|---|---|
| `GET` | `/<token>/` and allowlisted assets | none | Native editor HTML/JS/CSS |
| `GET` | `/<token>/api/snapshot` | none | Current snapshot JSON |
| `POST` | `/<token>/api/save` | `multipart/form-data` with `snapshot` and `png` | Embed the snapshot and atomically save the PNG |

Minimum HTTP errors:

| Status | Code | Meaning |
|---|---|---|
| `400` | `INVALID_REQUEST`, `INVALID_MULTIPART`, `INVALID_SNAPSHOT`, or PNG validation code | Malformed framing or invalid body |
| `404` | `NOT_FOUND` | Wrong token, route, or asset without revealing which |
| `409` | `TARGET_CHANGED` | Fixed target changed since session preflight |
| `415` | `UNSUPPORTED_MEDIA_TYPE` | Wrong request or part content type |
| `500` | `SAVE_FAILED` | Sanitized server-side persistence failure |

Quickdraw's `onSave(blob)` creates native `FormData` containing exactly two parts: `snapshot` as `application/json` and `png` as `image/png`. Lua parses and validates both from the same request before writing anything. Unknown, missing, or duplicate parts are rejected. This single request needs no staged server state, client save queue, base64 expansion, or external multipart dependency.

### Loading and persistence

- `start()` preflights the fixed absolute path before binding or opening a browser.
- A missing target opens an empty Quickdraw snapshot and is created only after a successful save.
- An existing valid Quickdraw PNG restores its embedded snapshot.
- A corrupt PNG, unreadable target, or existing ordinary PNG without Quickdraw metadata fails preflight rather than being overwritten.
- Retain the exact preflighted target bytes privately. Before saving, reject a target that appeared, disappeared, was replaced, or changed in place since startup.
- The multipart body must contain exactly one JSON object and one PNG; PNG bytes are validated by `quickdraw.png.embed_snapshot()`.
- Save to a sibling temporary file, close it, then replace the target with `vim.loop.fs_rename`. Any conflict, parse, encode, write, or rename failure leaves the previous target unchanged and removes the temporary file.

### Server and security boundary

- Use Neovim 0.8-compatible `vim.loop` APIs; add no Lua HTTP framework.
- Bind only `127.0.0.1` with port `0`; never bind all interfaces.
- Generate 32 bytes from an OS CSPRNG and encode them URL-safely. Use `vim.loop.random` when available, `/dev/urandom` through `vim.loop` on Unix Neovim 0.8, and PowerShell `RandomNumberGenerator` without shell interpolation on Windows Neovim 0.8. Never fall back to `math.random`; fail `start()` with `TOKEN_FAILED` if entropy is unavailable.
- Before buffering a body, cap the request line at 8 KiB and all headers at 32 KiB, validate framing plus token/route, and reject `Transfer-Encoding`. Apply a five-second inactivity timeout reset after each received chunk.
- Retain the artifact format's body ceiling instead of adding a smaller plugin payload limit. Valid bodies remain in memory, matching `quickdraw.png`.
- Set `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and `Cache-Control: no-store`; restrict scripts and connections to self.

### Lifecycle and browser launch

- A successful replacement becomes active only after its listener is ready, then closes the previous session; failed preflight or listener setup preserves the current session.
- `stop()` closes clients/listener and invalidates the URL.
- Register cleanup for `VimLeavePre`.
- Launch without interpolating user data into a shell command: `open` on macOS, `xdg-open` on Linux, and a native Windows launcher.
- Default-browser launch verification and isolated-browser product verification are separate. The smoke test manually opens the returned URL in a browser started with a temporary profile.

## Task List

### Phase 1: Offline dependency and server foundation

- [x] Task 1: Vendor the published Quickdraw core package
- [x] Task 2: Implement bounded loopback HTTP framing and routing

### Checkpoint: Server foundation

- [x] The server accepts only the documented loopback HTTP subset.
- [x] Unauthenticated or malformed requests cannot escape routing or hold unbounded framing state.

### Phase 2: Loadable editor

- [x] Task 3: Serve a blank native Quickdraw editor
- [x] Task 4: Preflight and load the fixed target snapshot

### Checkpoint: Load flow

- [x] A real browser renders a blank and an existing drawing without external requests.
- [x] Invalid tokens, asset paths, requests, and PNG targets expose no data and modify no files.

### Phase 3: Save and lifecycle

- [x] Task 5: Save snapshot JSON and PNG through one multipart request
- [x] Task 6: Complete singleton lifecycle and platform launch behavior

### Checkpoint: Complete

- [x] The browser can draw, save, close, reopen, and restore the same Quickdraw document.
- [x] The saved file remains a valid viewable PNG with exactly one Quickdraw metadata chunk.
- [ ] Unit, integration, formatting, compatibility, and real-browser checks pass. Local gates and macOS smoke pass; the configured Linux/macOS/Windows CI matrix requires a committed run.

## Verification Strategy

Implementation follows RED -> GREEN for each behavior using the existing Plenary harness.

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/quickdraw/session_spec.lua"
make test
stylua --check lua tests
git diff --check
```

Required real-browser smoke in a temporary browser profile:

1. Start a session for a temporary absolute PNG path and copy its returned URL.
2. Open that URL in the isolated test browser; separately verify the default-browser launcher receives the same URL.
3. Confirm the board renders with no console errors or external network requests.
4. Draw a visible stroke and use Quickdraw's Save PNG action.
5. Confirm one multipart `POST /api/save` contains the snapshot and PNG and succeeds.
6. Confirm an ordinary image viewer opens the saved PNG.
7. Stop and reopen the session, then confirm the same editable stroke is restored.
8. Confirm the old token/URL no longer responds after stop or replacement.

CI retains Linux, macOS, and Windows across Neovim `v0.8.0`, stable, and nightly. Browser smoke is a documented local/manual gate unless a browser runner is later added explicitly.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Hand-written HTTP framing is malformed or hangs Neovim | High | Support only HTTP/1.1 with `Content-Length` and connection close; cap framing, time out idle clients, and test fragmented/malformed requests |
| Static routing exposes runtime files | High | Exact asset allowlist; no URL-to-path joining; raw and encoded traversal tests |
| Multipart parsing confuses body data with a boundary | High | Parse standard CRLF-delimited boundaries, require exactly two named parts, and test boundary-like bytes inside PNG data |
| Browser-controlled input writes arbitrary files | High | Fix the trusted absolute path at `start()`; routes accept no path or filename |
| Failed save corrupts an existing drawing | High | Validate before writing; use sibling temp plus atomic rename; test every failure path |
| Token generation is weak or unavailable on Neovim 0.8 | High | OS CSPRNG only, platform compatibility tests, and fail closed |
| Quickdraw upstream changes or disappears | Medium | Vendor exact npm 0.2.0 contents, manifest, integrity, and MIT license; no runtime fetch |
| Large snapshots exhaust memory | Medium | Preserve the approved artifact limit and in-memory model; document the ceiling rather than adding a conflicting lower limit |
| Browser behavior passes Lua tests but fails in reality | Medium | Require isolated real-browser rendering, console, network, save, and reopen checks |
| Platform launch or replacement differs | Medium | Keep launch failure non-fatal; exercise filesystem and launcher seams on the existing OS/Neovim CI matrix |

## Open Questions

None. Product decisions were confirmed before planning. Implementation begins only after human approval of this plan.
