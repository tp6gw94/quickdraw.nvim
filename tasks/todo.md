# Tasks: editor-session

## Task 1: Vendor the published Quickdraw core package

**Description:** Check in the published `@quickdrawjs/core` 0.2.0 package as immutable browser assets with reproducible provenance. This task does not add application code or attempt to use endpoints that do not exist yet.

**Acceptance criteria:**

- [x] The recorded npm tarball URL and SRI authenticate the downloaded 0.2.0 tarball; a checked-in SHA-256 manifest matches its extracted published files.
- [x] The vendored tree includes the MIT license and every relative ESM/CSS import resolves to a checked-in file.
- [x] No package manager, build step, CDN, or external resource is required at runtime.

**Verification:**

- [x] Download the recorded tarball, verify its SRI, extract it, regenerate the manifest, and diff it against the vendored tree.
- [x] Check all ESM and CSS imports against the vendored file manifest.
- [x] `git diff --check` passes.

**Dependencies:** None

**Files likely touched:**

- `web/quickdraw/vendor/@quickdrawjs/core/` — mechanical published package contents
- `web/quickdraw/vendor/@quickdrawjs/core/LICENSE`
- `web/quickdraw/vendor/@quickdrawjs/core/INTEGRITY`
- `web/quickdraw/vendor/@quickdrawjs/core/MANIFEST.sha256`

**Estimated scope:** Small — one mechanical vendor artifact plus provenance files

## Task 2: Implement bounded loopback HTTP framing and routing

**Description:** Build the minimum Neovim 0.8-compatible `vim.loop` HTTP engine required by this capability. It accepts one HTTP/1.1 request per connection, validates framing before buffering bodies, routes only exact token-scoped entries, and tears down deterministically.

**Acceptance criteria:**

- [x] The listener binds only `127.0.0.1:0`; token generation uses 32 OS-random bytes and fails closed when no approved entropy source is available.
- [x] Fragmented requests with valid `Content-Length` are assembled; oversized request lines/headers, invalid lengths, transfer encoding, malformed framing, unknown routes, wrong tokens, and idle clients are rejected and closed.
- [x] Routing uses an exact in-memory route map rather than joining browser paths to filesystem paths; raw/encoded traversal, backslashes, NULs, and unknown assets cannot escape the allowlist.

**Verification:**

- [x] RED then GREEN focused tests cover fragmented reads, 8 KiB request-line and 32 KiB header ceilings, five-second inactivity handling, token generation/failure, and malformed requests.
- [x] Real ephemeral-socket tests prove loopback binding, token rejection, exact routing, connection close, and stopped-listener behavior.
- [x] The existing CI matrix remains configured to run `make test` on Neovim 0.8, stable, and nightly; local `make test`, `stylua --check lua tests`, and `git diff --check` pass.

**Dependencies:** Task 1

**Files likely touched:**

- `lua/quickdraw/session.lua`
- `tests/quickdraw/session_spec.lua`

**Estimated scope:** Medium — 2 files with one constrained protocol seam

## Checkpoint: Server foundation

- [x] The server accepts only the documented loopback HTTP subset.
- [x] Unauthenticated or incomplete clients cannot cause unbounded header growth or hold handles indefinitely.
- [x] Static route input cannot address arbitrary runtime or filesystem files.

## Task 3: Serve a blank native Quickdraw editor

**Description:** Add the native HTML/JS shell and serve it plus the vendored Quickdraw assets through the exact route map. A missing target returns an empty snapshot so this task delivers the first browser-visible vertical slice. This milestone returns a URL for manual opening; automatic browser launch remains Task 6.

**Acceptance criteria:**

- [x] `start({ path = <missing absolute PNG> })` returns `{ url, path, browser_opened = false, warning = nil }` and serves HTML/JS/CSS with correct content types and restrictive security headers.
- [x] `index.html` imports only checked-in ESM/CSS; `app.js` uses `createQuickdraw()` and renders a blank board from `GET /<token>/api/snapshot` without React or runtime npm.
- [x] The returned page makes no automatic external request and shows a visible same-origin error if a valid session later fails.

**Verification:**

- [x] RED then GREEN tests cover missing-target startup, static responses, snapshot `{}`, security headers, and sanitized error bodies.
- [x] Open the returned URL in a temporary browser profile; confirm the board renders, the console is clean, and network traffic remains same-origin.
- [x] `make test`, `stylua --check lua tests`, and `git diff --check` pass.

**Dependencies:** Task 2

**Files likely touched:**

- `lua/quickdraw/session.lua`
- `web/quickdraw/index.html`
- `web/quickdraw/app.js`
- `tests/quickdraw/session_spec.lua`

**Estimated scope:** Medium — 4 authored files

## Task 4: Preflight and load the fixed target snapshot

**Description:** Preflight the one trusted absolute PNG path before binding. Existing Quickdraw PNGs load through `quickdraw.png`; targets that could be destroyed accidentally fail before a server or browser starts.

**Acceptance criteria:**

- [x] A valid existing Quickdraw PNG is preflighted and `GET /<token>/api/snapshot` returns its exact embedded object.
- [x] Existing ordinary PNGs without Quickdraw metadata, corrupt PNGs, unreadable targets, relative/invalid paths, and parser failures return stable errors before listener/browser startup and never modify disk.
- [x] `app.js` loads the returned object with source `remote` and fits existing content.

**Verification:**

- [x] RED then GREEN tests cover valid, ordinary, corrupt, unreadable, relative, and invalid targets, including absence of server/browser side effects on failure.
- [x] A real loopback request returns the same snapshot previously embedded by `quickdraw.png`.
- [x] Isolated-browser smoke opens an existing artifact and visually confirms its content; automated repository gates pass.

**Dependencies:** Task 3

**Files likely touched:**

- `lua/quickdraw/session.lua`
- `web/quickdraw/app.js`
- `tests/quickdraw/session_spec.lua`

**Estimated scope:** Medium — 3 files

## Checkpoint: Load flow

- [x] A real browser renders both a new blank drawing and an existing editable drawing.
- [x] Invalid tokens, asset paths, requests, and PNG targets expose no data and modify no files.
- [x] Existing artifact-format tests remain green.

## Task 5: Save snapshot JSON and PNG through one multipart request

**Description:** Implement one `POST /<token>/api/save` endpoint. Quickdraw's `onSave(blob)` sends native `FormData` containing the current `store.getSnapshot()` JSON and exported PNG; Lua validates both, embeds the snapshot, and atomically replaces only the fixed target.

**Acceptance criteria:**

- [x] The request must contain exactly one `snapshot` part with `application/json` and one `png` part with `image/png`; missing, duplicate, unknown, malformed, or path-like parts are rejected before writing.
- [x] Success produces a viewable PNG whose `quickdraw.png.extract_snapshot()` result exactly equals the submitted JSON object.
- [x] Before writing, a missing target must still be missing and an existing target must still match its retained identity and exact bytes; conflicts return `TARGET_CHANGED` without writing.
- [x] Invalid multipart framing, JSON, PNG, media type, embed, write, rename, or target-conflict handling returns the documented status/code, removes temporary output, and preserves the previous target byte-for-byte.

**Verification:**

- [x] RED then GREEN tests cover success, repeated replacement, missing/duplicate/unknown parts, boundary-like bytes inside PNG data, malformed inputs, target appearance/disappearance/replacement/in-place modification, write/rename failures, and a payload larger than 16 MiB.
- [x] A real HTTP integration test sends one native multipart request and reopens the saved bytes through `quickdraw.png.extract_snapshot()`.
- [x] Isolated-browser smoke draws and saves while DevTools confirms one multipart `POST`, a successful response, no external traffic, and a clean console; automated repository gates pass.

**Dependencies:** Task 4

**Files likely touched:**

- `lua/quickdraw/session.lua`
- `web/quickdraw/app.js`
- `tests/quickdraw/session_spec.lua`

**Estimated scope:** Medium — 3 files

## Task 6: Complete singleton lifecycle and platform launch behavior

**Description:** Finish session replacement, Neovim-exit cleanup, and default-browser launch while keeping browser-opening failure non-fatal. Qualify the complete save/stop/reopen flow independently in an isolated browser.

**Acceptance criteria:**

- [x] Starting a session stops the previous one; repeated `stop()` succeeds; `VimLeavePre` closes listener/client handles and invalidates the old token.
- [x] macOS, Linux, and Windows launchers receive the URL without user-controlled shell interpolation; failure returns `{ browser_opened = false, warning = { code = "BROWSER_OPEN_FAILED", ... } }` while the URL remains usable.
- [x] Opening the returned URL in a separate temporary-profile browser supports draw, save, stop, reopen, and editable snapshot restoration without console errors or external requests.

**Verification:**

- [x] Focused tests cover session replacement, repeated stop, exit cleanup, token invalidation, launcher selection, and non-fatal launcher failure.
- [x] Separately verify the default launcher receives the URL and run the product smoke by manually opening that URL in an isolated browser profile.
- [ ] `make test`, `stylua --check lua tests`, `git diff --check`, and the existing Neovim/OS CI matrix pass. Local gates pass; the configured cross-platform matrix requires a committed CI run.

**Dependencies:** Task 5

**Files likely touched:**

- `lua/quickdraw/session.lua`
- `tests/quickdraw/session_spec.lua`
- `web/quickdraw/app.js` only if runtime verification exposes an integration defect

**Estimated scope:** Medium — 2 files plus one conditional integration fix file

## Checkpoint: Complete

- [x] An absolute target path supplied to `start()` opens automatically in the native Quickdraw editor.
- [x] Save writes one ordinary viewable PNG containing the complete editable snapshot.
- [x] Closing and reopening restores the same drawing.
- [x] Browser input cannot select another filesystem path or reach a stopped session.
- [ ] All automated gates and the real-browser smoke pass. Local gates and smoke pass; cross-platform CI is pending a committed run.
- [x] Human reviews and approves the result before `neovim-integration` begins.
