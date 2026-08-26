# Spec: editor-session

Module id: `editor-session`

## Objective

Run one offline Quickdraw browser editor for an absolute PNG target. The session serves bundled assets over an authenticated loopback URL, loads and saves editable Quickdraw snapshots, eagerly creates a blank artifact whenever the target is missing, and reports whether the browser's current document state is persisted.

A prompted Neovim creation must leave a valid PNG on disk before its Markdown link is inserted. A same-name target must never be opened or overwritten by that creation flow.

## Tech Stack

- Neovim Lua
- Neovim >= 0.8
- Neovim's bundled libuv through `vim.loop`
- Native HTML, CSS, and JavaScript
- Existing vendored `@quickdrawjs/core`
- Existing `quickdraw.png` metadata API
- Plenary/Busted and Node's built-in test runner
- No runtime dependencies or external network access

## Session Interface

`quickdraw.session` remains an internal integration boundary.

```lua
quickdraw.session.start({
  path = absolute_png_path,
  create = true,
})
```

Rules:

- `path` must be an absolute `.png` path.
- `create` defaults to `false`.
- `create = false` preserves edit behavior: an existing Quickdraw PNG opens, an ordinary or invalid PNG is rejected, and a missing linked PNG is eagerly created as a valid blank Quickdraw PNG before returning success.
- `create = true` is only for prompted creation. It requires the target path to be absent and creates the same valid blank Quickdraw PNG before returning success.
- In prompted `create = true` mode, check the exact target path before staging. Any existing filesystem entry, including a Quickdraw PNG, ordinary file, directory, or symbolic link, returns `TARGET_EXISTS` with the stable message `A drawing with that name already exists. Choose another name.`
- Every creation failure returns a structured error with a non-empty sanitized reason for the Neovim notification boundary. No failure inserts Markdown.
- The existence preflight improves the message, but an atomic no-replace hard link is the authority. A race that creates the target after preflight also returns `TARGET_EXISTS` without changing that target.
- Starting a successful session replaces the prior process-wide session. A failed preflight, staging, server preparation, or target commit leaves the prior session active.

## Blank Artifact Creation

The initial artifact is a standard transparent 1 x 1 PNG containing an empty Quickdraw snapshot:

```json
{
  "document": {
    "store": {}
  }
}
```

Rules:

- Use the bundled `web/quickdraw/blank.png` as the image seed and embed the snapshot through `quickdraw.png`; do not duplicate PNG bytes or metadata encoding in Lua or JavaScript.
- Prepare the new listener and all other fallible session resources without replacing the active session.
- Then write and verify the complete blank artifact in an exclusively opened temporary file beside the target. A staging failure never creates the target.
- Recheck the staged path identity and immediately commit it to the target with an atomic same-filesystem hard link. The link must fail when any target entry exists and must never truncate or replace it.
- Do not use check-then-unlink rollback on the target. After the hard link succeeds, only non-failing session activation remains; the target is never removed by startup cleanup.
- Best-effort remove the temporary name after linking; the target retains the verified inode and bytes as its session baseline. A cleanup failure may leave only the plugin-owned temporary hard link and must not invalidate or remove the target.
- If the platform or filesystem cannot provide the no-replace hard-link operation, fail safely without creating the target or inserting Markdown.
- Browser launch failure remains a successful session with the existing manual-URL warning.

## Browser API

All routes remain same-origin beneath the unguessable session-token URL.

### Load

```http
GET /api/snapshot
```

```json
{
  "document": {
    "store": {}
  }
}
```

The response body remains the editable Quickdraw snapshot object. A successful browser session always has an existing target baseline because missing targets are created before the session URL is returned.

### Save

```http
POST /api/save
Content-Type: multipart/form-data
```

The existing request and response contract remains:

- `snapshot`: JSON object
- `png`: exported PNG bytes
- Success: `200 {"ok":true}`
- Invalid input, target conflict, or write failure returns the existing sanitized JSON error response.
- Successful writes remain atomic and update the session snapshot and target baseline.
- The browser serializes save jobs in host-callback order. Request B cannot reach the server until request A has completed.
- The PNG blob passed by the vendored callback is treated only as a save intent. When a job reaches the head of the queue, the host synchronously captures the current revision and snapshot, starts a fresh whole-board export, and then sends that paired payload.
- `editor.exportImage()` captures its immutable shape list synchronously before its first await, so the fresh PNG and snapshot represent the same document revision.
- Out-of-order completion of the vendored callback's preliminary exports cannot regress the saved document: every queued job performs a fresh capture when it begins.
- After the queue drains successfully, the PNG metadata and pixels correspond to the newest job capture.

## Save Status UI

**Design read:** preserve the existing Quickdraw product UI and add a quiet, functional persistence indicator rather than introducing a new visual system.

```text
DESIGN_VARIANCE: 3
MOTION_INTENSITY: 2
VISUAL_DENSITY: 4
```

Use native CSS matching the existing floating chrome. Do not add a dependency, icon library, animation framework, or vendored-core modification.

The host app must support saving an empty document without changing the vendored core. For whole-board export only, wrap the editor instance's export call: when the core returns `null` because no shapes exist, supply `web/quickdraw/blank.png` as the PNG blob. Selection export keeps the core's existing `null` behavior.

Visible states:

| State | Text | Meaning |
|---|---|---|
| Saved | `Saved` | The displayed document revision is persisted |
| Unsaved | `Unsaved` | A user edit occurred after the last successful save |
| Saving | `Saving…` | A save request for a captured revision is in progress |
| Failed | `Save failed` | The latest save attempt failed and the document remains unsaved |

Behavior:

1. After `GET /api/snapshot` loads successfully, initialize as `Saved`; session startup guarantees that the target PNG already exists.
2. Listen to `board.editor.store` changes whose source is `user` and mark the document unsaved.
3. Treat each vendored save callback as an intent, assign its attempt number, and enqueue it. Show `Saving…` while the newest intent is pending or running unless a newer user edit exists.
4. Execute jobs serially in callback order. At the head of the queue, synchronously capture the current revision and snapshot, begin a fresh whole-board export, and send only that paired payload.
5. Mark saved only when the newest attempt succeeds and its job-start revision still equals the current user revision.
6. A user edit during saving immediately changes the visible state to `Unsaved`; success of the older request leaves it `Unsaved`.
7. Success or failure from a stale attempt cannot change status or clear/show the error alert.
8. Failure of the newest attempt shows `Save failed` and the existing alert. The next user edit changes status to `Unsaved` and clears that stale save error.
9. Saving an empty document uses the bundled blank PNG fallback and follows the same state transitions.
10. Do not autosave, poll the filesystem, or add a navigation warning.

Accessibility and presentation:

- Render status inside the board chrome in a quiet top-right position that does not cover the toolbar, actions, watermark, or error alert.
- Expose status through `role="status"` and `aria-live="polite"`.
- Use visible text, not color alone.
- Preserve the assertive error alert for failures.
- Match both existing light and dark board themes through semantic CSS selectors.
- Use only opacity or transform for any brief state transition and disable it under reduced motion. Static transitions are acceptable.
- Remain legible and non-overlapping at 320, 768, 1024, and 1440 pixel widths.

## Commands

```text
All tests:           make test
Focused session:     nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/quickdraw/session_spec.lua"
Browser state tests: node --test tests/web/save_status_test.mjs
JavaScript syntax:   node --check web/quickdraw/app.js && node --check web/quickdraw/save_status.js
Format:              stylua lua tests
Lint:                stylua --check lua tests
Build:               none
```

## Project Structure

```text
lua/quickdraw/
├── png.lua                    PNG metadata encoding and decoding
├── session.lua                Session lifecycle, target creation, HTTP, load, and save
└── session_state.lua          Process-wide active session

web/quickdraw/
├── blank.png                  Canonical transparent 1 x 1 PNG seed
├── index.html                 Board, status, and error surfaces
├── app.css                    Host status and error styles
├── app.js                     Editor bootstrap, load/save wiring, and empty export fallback
├── save_status.js             Importable revision and serialized-save controller
└── vendor/                    Unmodified bundled Quickdraw core

tests/
├── fixtures/blank.png         Standard blank PNG seed
├── quickdraw/session_spec.lua Session, creation, conflict, and HTTP tests
└── web/save_status_test.mjs   Save-state transition tests using Node built-ins
```

## Code Style

```js
board.editor.store.listen(() => {
  saveStatus.markUnsaved()
}, { source: "user" })
```

Conventions:

- Lua and JavaScript functions use `snake_case` and `camelCase` respectively.
- Keep filesystem and HTTP errors structured internally and sanitized at user boundaries.
- Keep the dependency-free save controller importable with injected capture, request, and render callbacks so Node can test it without a DOM library.
- Use one revision counter, one save-attempt counter, and one promise queue. Capture payloads only when a job reaches the queue head; do not add a general state framework.
- Reuse `quickdraw.png` and existing target-baseline helpers.
- Do not modify vendored Quickdraw files for host-level persistence UI.

## Testing Strategy

Use TDD for new behavior.

Lua tests cover:

1. Prompted `create = true` and a missing cursor-linked `create = false` target both create a valid editable blank PNG with an empty object snapshot before success.
2. Prompted creation checks first; existing Quickdraw PNGs, ordinary files, directories, and symbolic links return `TARGET_EXISTS` with the stable reason and without byte changes.
3. A target created during the preflight race makes the atomic link fail, returns a structured reason, and is not overwritten.
4. Temporary write, verification, and close failures leave no target and permit a clean retry.
5. A replacement target created immediately before the commit link is never removed, including when it contains identical blank bytes.
6. Unsupported hard-link creation fails safely without a target or Markdown change.
7. Failed staging, server preparation, or target commit leaves the prior active session intact.
8. Browser launch failure retains the committed blank artifact and active session.
9. Snapshot responses retain the original plain snapshot-object contract for existing, prompted-created, and cursor-link-created targets.
10. Existing multipart validation, conflict detection, atomic saves, token handling, lifecycle cleanup, and asset serving remain green.

Node built-in tests cover:

1. Successful snapshot loading initializes `Saved`.
2. User edits mark the state unsaved; remote snapshot loading does not.
3. Save start, success, and failure transitions.
4. Editing during save immediately shows `Unsaved` and remains unsaved after the older request succeeds.
5. Jobs execute in callback order, capture only at the queue head, and the final persisted fixture contains the newest job-start revision.
6. Deferred preliminary exports completing out of invocation order cannot pair a stale PNG with a newer snapshot or regress the final saved document.
7. Stale success and failure cannot change status or mutate the error alert.
8. A newest-attempt failure shows the alert; the next edit clears that alert and shows `Unsaved`.
9. Empty-document save uses the blank PNG fallback and can reach `Saved`.
10. Plain snapshot validation, remote-load handling, status text, and ARIA attributes remain present.

Manual browser validation covers keyboard save, menu save, clearing then saving an empty board, light/dark themes, failure display, and responsive non-overlap.

`make test` runs both the Plenary suite and `node --test tests/web/save_status_test.mjs`; the existing CI workflow therefore exercises both without a new dependency. No coverage percentage is required.

## Boundaries

### Always

- Bind only to loopback and require the bearer-token URL prefix.
- Keep runtime behavior offline.
- Commit new targets with an atomic no-replace hard link and preserve existing targets byte-for-byte.
- Keep target-baseline conflict checks and atomic later saves.
- Make save status revision-aware and accessible.
- Keep generic errors free of the bearer token.

### Ask First

- Add autosave, before-unload prompts, retry controls, timestamps, parallel save requests, or notifications outside the browser.
- Change the PNG metadata schema or blank image dimensions.
- Change the internal snapshot HTTP response shape.
- Modify vendored Quickdraw code.
- Add a runtime or test dependency.

### Never

- Overwrite, truncate, open, unlink, or repurpose a same-name target during prompted creation.
- Insert a Markdown link before exclusive blank-artifact creation and session startup succeed.
- Claim a newer edited revision is saved because an older request succeeded.
- Send save requests concurrently or allow stale completion to mutate status or error UI.
- Follow a symbolic link when checking or creating a prompted target.
- Expose the bearer token in status text, generic errors, or logs.

## Success Criteria

- Prompted creation and missing cursor-linked creation leave a valid editable blank PNG on disk before the browser session succeeds.
- Any same-name filesystem entry produces `A drawing with that name already exists. Choose another name.` and no Markdown or target changes.
- Every successfully loaded browser session begins in the `Saved` UI state because its PNG already exists.
- User edits, serialized saves, edits during save, empty-document saves, and failures display truthful persistence status.
- After multiple queued saves complete, the target contains the newest job-start revision with matching snapshot metadata and PNG pixels.
- Existing edit-link, server security, browser fallback, conflict detection, and atomic-save behavior remain intact.
- Automated, formatting, syntax, diff, and manual browser checks pass.

## Open Questions

None.
