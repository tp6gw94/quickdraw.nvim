# Tasks: Blank Artifact Creation and Save Status

## Task 1: Add exclusive blank-artifact creation to editor sessions

**Description:** Add `create = true` to the internal session start contract. Use the canonical runtime blank PNG, embed an empty Quickdraw snapshot in a verified temporary inode, prepare the new session, and atomically hard-link that inode to the absent target without replace semantics.

**Acceptance criteria:**

- [x] A missing prompted `create = true` target and a missing cursor-linked `create = false` target both become valid transparent 1 x 1 Quickdraw PNGs with empty object snapshots before session success.
- [x] Prompted creation checks first; any existing file, directory, or symbolic link, including one created immediately before commit, makes the no-replace link return `TARGET_EXISTS` and remains unchanged.
- [x] Staging write, verification, close, server-preparation, hard-link, and unsupported-filesystem failures return a non-empty sanitized reason, leave no target, permit a clean retry, and preserve the prior active session.

**Verification:**

- [x] RED then GREEN tests cover prompted and missing-link success, all conflict types, temporary write/verification/close failure reasons, clean retry, replacement between preflight and link, identical-byte replacement, unsupported link, baseline establishment, prior-session preservation, and browser-launch warning behavior.
- [x] Focused session tests pass: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/quickdraw/session_spec.lua"`.
- [x] `stylua --check lua tests` and `git diff --check` pass.

**Dependencies:** None

**Files likely touched:**

- `web/quickdraw/blank.png`
- `lua/quickdraw/session.lua`
- `tests/quickdraw/session_spec.lua`

**Estimated scope:** Medium - 3 files

## Task 2: Use creation mode from the Neovim prompt flow

**Description:** Start prompted targets with `create = true`, surface `TARGET_EXISTS` through the existing command notification boundary, and preserve the original Markdown insertion context and no-reprompt behavior.

**Acceptance criteria:**

- [x] Prompted creation passes exactly `{ path = absolute_target, create = true }` after directory creation.
- [x] `TARGET_EXISTS` displays the stable replacement-name message, does not reopen input, and leaves Markdown unchanged.
- [x] Successful blank creation inserts the link afterward; cursor-linked editing continues without `create = true`.

**Verification:**

- [x] RED then GREEN tests cover creation options, conflict/no-reprompt, cancellation, successful insertion order, browser warning, and cursor edit options.
- [x] Focused integration tests pass: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/quickdraw/integration_spec.lua"`.
- [x] Full Lua tests, Stylua, and diff checks pass.

**Dependencies:** Task 1

**Files likely touched:**

- `lua/quickdraw.lua`
- `tests/quickdraw/integration_spec.lua`

**Estimated scope:** Small - 2 files

## Checkpoint: Creation contract

- [x] Prompted creation leaves a valid editable blank PNG before Markdown insertion.
- [x] Every same-name entry is rejected without target or buffer changes.
- [x] Existing cursor-linked edit behavior remains green.
- [x] Focused session and integration suites pass.

## Task 3: Build and test the serialized save-status controller

**Description:** Add one dependency-free controller for revision tracking, latest-attempt ownership, serialized job capture/request execution, status rendering, plain-snapshot validation, and save-error ownership. Integrate its Node built-in tests into the existing `make test` gate.

**Acceptance criteria:**

- [x] Initial saved state, user edits, save start, success, and latest failure produce the specified visible states.
- [x] Save intents execute in callback order and capture revision, snapshot, and a fresh export only when each job reaches the queue head; editing during save remains unsaved; stale completion cannot mutate status or alerts.
- [x] The controller is importable with injected callbacks and uses no DOM or runtime dependency.

**Verification:**

- [x] RED then GREEN Node tests cover controller state transitions, queue-head capture, newest paired payload ordering, queued edits, edit-during-save, stale failure ownership, plain-snapshot validation, and alert clearing on edit.
- [x] `node --test tests/web/save_status_test.mjs` passes.
- [x] `make test` runs both the Plenary and Node suites successfully.

**Dependencies:** None

**Files likely touched:**

- `web/quickdraw/save_status.js`
- `tests/web/save_status_test.mjs`
- `Makefile`

**Estimated scope:** Medium - 3 files

## Task 4: Preserve snapshot loading and serve browser support assets

**Description:** Keep `GET /api/snapshot` as the original plain snapshot object, serve the blank PNG and save-controller module under the tokenized origin, and prove every successful session already has a target PNG.

**Acceptance criteria:**

- [x] Existing, prompted-created, and cursor-link-created sessions all return the original plain snapshot object and have an established target baseline.
- [x] No `saved` field or snapshot envelope is added.
- [x] `blank.png` and `save_status.js` are served with correct content types under the authenticated route prefix only.

**Verification:**

- [x] RED then GREEN session tests cover plain responses for all session paths, target existence/baselines, asset bytes/content types, and route authentication.
- [x] Focused session tests and JavaScript syntax checks pass.
- [x] Existing server security, snapshot, and asset tests remain green.

**Dependencies:** Tasks 1 and 3

**Files likely touched:**

- `lua/quickdraw/session.lua`
- `tests/quickdraw/session_spec.lua`

**Estimated scope:** Small - 2 files

## Task 5: Integrate accessible save status and empty-board saving

**Description:** Connect browser load/save wiring to the controller, add the status surface and theme-aware styles, and wrap whole-board export so an empty store saves with the canonical blank PNG while selection export remains unchanged.

**Acceptance criteria:**

- [x] Every successful plain-snapshot load initializes `Saved`; the board then displays `Saved`, `Unsaved`, `Saving…`, or `Save failed` truthfully with `role="status"`, `aria-live="polite"`, and text independent of color.
- [x] Empty whole-board keyboard/menu saves reach the normal save endpoint; deferred preliminary exports, edits during save, and repeated saves obey queue-head capture and controller ordering.
- [x] Status and error UI work in light/dark themes without overlap at 320, 768, 1024, and 1440 pixel widths.

**Verification:**

- [x] Node tests cover valid/malformed plain snapshots, initial `Saved`, controller ordering, the empty-export helper, status text, and ARIA markup.
- [x] `node --test tests/web/save_status_test.mjs` and JavaScript syntax checks pass.
- [x] Manual browser validation covers real app wiring, keyboard/menu save, clear/save/reopen, failure recovery, light/dark themes, accessibility attributes, and 320/768/1024/1280/1440 placement.

**Dependencies:** Tasks 3 and 4

**Files likely touched:**

- `web/quickdraw/app.js`
- `web/quickdraw/save_status.js`
- `web/quickdraw/index.html`
- `web/quickdraw/app.css`
- `tests/web/save_status_test.mjs`

**Estimated scope:** Medium - 5 files

## Checkpoint: Browser persistence flow

- [x] Initial, edited, saving, saved, and failed states are truthful.
- [x] Editing during save remains unsaved after older completion.
- [x] Multiple saves persist matching snapshot metadata and PNG pixels from the newest job-start revision.
- [x] Keyboard and menu save work after clearing the board.
- [x] Light/dark and responsive layouts remain legible and non-overlapping.

## Task 6: Update documentation and run complete validation

**Description:** Document immediate blank-file creation, same-name rejection, and browser save states. Run all automated, provenance, diff, and manual user-flow gates against the final implementation.

**Acceptance criteria:**

- [x] README and vimdoc explain that prompted and missing-link sessions create a blank PNG before browser success, conflicts require another name, and every successful load begins saved.
- [x] Documentation preserves cursor-linked edit behavior and does not promise autosave or automatic re-prompting.
- [x] All approved spec success criteria are verified with no vendored-core changes.

**Verification:**

- [x] `make test`, `stylua --check lua tests`, both JavaScript syntax checks, and `git diff --check` pass.
- [x] `git diff --exit-code HEAD -- web/quickdraw/vendor/@quickdrawjs/core` confirms this feature adds no vendor changes; record the approved pre-existing `cf26d49` manifest mismatch.
- [x] Manual create, conflict, edit, repeated save, empty save, failure, image-asset save, responsive layout, and reopen flows pass.

**Dependencies:** Tasks 1-5

**Files likely touched:**

- `README.md`
- `doc/quickdraw.txt`

**Estimated scope:** Small - 2 files

## Checkpoint: Complete

- [x] All automated and manual gates pass.
- [x] Fresh-context review findings are resolved or explicitly deferred.
- [x] Final diff matches `SPEC-editor-session.md` and `SPEC-neovim-integration.md`.
- [ ] Human reviews and approves the completed capability.
