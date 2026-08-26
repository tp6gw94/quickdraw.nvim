# Implementation Plan: Blank Artifact Creation and Save Status

## Overview

Implement the approved `SPEC-editor-session.md` and updated `SPEC-neovim-integration.md` contracts. Prompted creation will exclusively create a valid empty Quickdraw PNG before inserting Markdown, reject every same-name filesystem entry with a replacement-name message, and preserve cursor-linked edit behavior. The browser will show truthful `Saved`, `Unsaved`, `Saving…`, and `Save failed` states, serialize saves, and support saving an empty board.

## Approved Scope

- Add `quickdraw.session.start({ path, create = true })` for prompted creation.
- Eagerly create the same blank PNG when a cursor-linked target is missing.
- Exclusively create a transparent 1 x 1 Quickdraw PNG with an empty snapshot.
- Check prompted targets before staging and return a visible `TARGET_EXISTS` reason for any same-name file, directory, or symbolic link.
- Keep the original target and Markdown buffer unchanged on conflict.
- Do not reopen the name prompt after conflict.
- Insert Markdown only after blank creation and session startup succeed.
- Add an accessible persistence indicator to the browser editor.
- Serialize saves and prevent stale completion from changing status, alerts, or final persisted content.
- Save cleared or otherwise empty boards using the bundled blank PNG fallback.
- Keep runtime offline and dependency-free.

## Non-goals

- Autosave, retry controls, timestamps, before-unload prompts, or filesystem polling.
- Renaming, replacing, or opening a conflicting prompted target.
- Changing cursor-linked missing/existing PNG behavior.
- Changing the Quickdraw metadata schema or adding a sidecar file.
- Modifying vendored `@quickdrawjs/core` files.
- Adding a runtime or test dependency.

## Dependency Graph

```text
runtime blank PNG
        |
        v
exclusive create=true session path
        |
        v
Neovim prompted creation + TARGET_EXISTS handling

save-status controller + serialized queue
        |
        v
browser support asset routes
        |
        v
browser status UI + empty-board fallback
        |
        v
documentation + full user-flow validation
```

Tasks 1 and 3 are technically independent, but use one serial writer to keep the active checkout and test baseline stable. Task 2 depends on Task 1. Task 4 depends on Tasks 1 and 3. Task 5 depends on Tasks 3 and 4. Documentation follows verified behavior.

## Architecture Decisions

### Editor session owns target creation

`neovim-integration` resolves the target and handles structured errors. `editor-session` owns exact-entry checks, exclusive creation, race handling, file identity, cleanup, and the stable `TARGET_EXISTS` error. This keeps persistence policy in one module.

### One canonical blank seed

Promote the existing 68-byte transparent 1 x 1 PNG shape into `web/quickdraw/blank.png`. Lua reads that runtime asset and embeds the empty snapshot through `quickdraw.png`. The browser uses the same served asset when whole-board export returns `null` for an empty store. Do not duplicate PNG bytes in source.

### Staged creation with atomic no-replace commit

Prepare the listener and other fallible session resources without replacing the active session. Then write and verify the blank artifact in an exclusively opened temporary file beside the target, recheck its identity, and immediately hard-link it to the absent target. The link fails if any entry won the race. This avoids both partial targets and unsafe check-then-unlink rollback. A filesystem without hard-link support fails safely; failure to remove the plugin-owned temporary hard-link name is reported as residual cleanup risk rather than deleting or invalidating the target.

### Preserve existing save replacement

The first blank artifact establishes an ordinary existing target baseline. Subsequent saves continue through the current temp-file verification and atomic rename path.

### Dependency-free save controller

Add one importable `save_status.js` controller with injected render, error, and request callbacks. It owns the revision counter, attempt counter, and promise queue. Node's built-in test runner can verify ordering and stale-completion behavior without a DOM library.

### Serialized save ordering and capture

Treat the vendored callback as a save intent and ignore its preliminary PNG payload. Queue intents in callback order. When a job reaches the queue head, synchronously capture the current revision and snapshot and start a fresh whole-board export before sending the paired payload. This prevents out-of-order preliminary exports from pairing stale pixels with newer metadata or regressing the final document. An edit during saving immediately wins the visible state; only the newest attempt may mutate status or the save-error alert.

### Host-level empty export fallback

Keep vendored core unchanged. Wrap whole-board export on the editor instance so a `null` empty export loads the served blank PNG blob. Selection export retains its existing `null` behavior.

### Native status chrome

Place one text status inside the board at the top right with `role="status"` and `aria-live="polite"`. Use native CSS tied to the board's existing light/dark theme attribute. No icons, animation library, or extra controls are needed.

## Task List

### Phase 1: Safe prompted creation

- [x] Task 1: Add exclusive blank-artifact creation to editor sessions.
- [x] Task 2: Use creation mode from the Neovim prompt flow and handle conflicts.

### Checkpoint: Creation contract

- [x] Prompted creation leaves a valid editable blank PNG before Markdown insertion.
- [x] Every same-name entry returns the stable replacement-name message without target or buffer changes.
- [x] Existing cursor-linked edit behavior remains green.
- [x] Focused session and integration suites pass.

### Phase 2: Persistence state

- [x] Task 3: Build and test the serialized save-status controller.
- [x] Task 4: Preserve snapshot loading and serve browser support assets.
- [x] Task 5: Integrate the accessible status UI and empty-board saving.

### Checkpoint: Browser persistence flow

- [x] Every successful load begins saved; edited, saving, saved, and failed states remain truthful.
- [x] Editing during save remains unsaved after the older request completes.
- [x] Multiple save intents persist matching snapshot metadata and PNG pixels from the newest job-start revision.
- [x] Keyboard and menu save work after clearing the board.
- [x] Light/dark and 320/768/1024/1440 layouts remain legible and non-overlapping.

### Phase 3: Documentation and final gates

- [x] Task 6: Update user documentation and run complete validation.

### Checkpoint: Complete

- [x] `make test` passes, including Lua and Node tests.
- [x] `stylua --check lua tests` passes.
- [x] JavaScript syntax checks pass.
- [x] No new working-tree changes exist beneath `web/quickdraw/vendor/@quickdrawjs/core/`; the approved pre-existing manifest mismatch is recorded as residual risk.
- [x] `git diff --check` passes.
- [x] Manual create, conflict, edit, clear, save, failure, image-asset, responsive, and reopen flows pass.
- [x] Fresh-context review findings are resolved or explicitly deferred.
- [ ] Human reviews and approves the completed capability.

## Verification Strategy

### Focused automated checks

```text
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/quickdraw/session_spec.lua"
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/quickdraw/integration_spec.lua"
node --test tests/web/save_status_test.mjs
```

### Full local gates

```text
make test
stylua --check lua tests
node --check web/quickdraw/app.js
node --check web/quickdraw/save_status.js
git diff --check
```

Verify this feature adds no vendor changes:

```text
git diff --exit-code HEAD -- web/quickdraw/vendor/@quickdrawjs/core
```

The published-package manifest already differs at `src/ui.js` because tracked commit `cf26d49` added the existing Ctrl/Cmd+S shortcut without changing the upstream provenance manifest. This pre-existing mismatch is not part of this feature.

### Manual user flow

1. Create a drawing from Markdown and confirm the PNG exists before interacting with the browser.
2. Open a cursor-linked missing PNG and confirm it is also created before the browser session succeeds.
3. Confirm every successful browser load begins `Saved` and the Markdown link resolves immediately.
4. Attempt the same name again and confirm the exact replacement-name message, unchanged PNG bytes, unchanged Markdown, and no repeated prompt.
5. Force a creation failure and confirm its sanitized reason is shown with no Markdown insertion.
6. Edit the board and confirm `Unsaved`; save and confirm `Saving…` then `Saved`.
7. Edit during a delayed save and confirm the newer revision remains `Unsaved`.
8. Complete two preliminary exports out of invocation order and confirm each queued job performs a fresh paired capture.
9. Trigger two saves around separate edits and confirm the final reopened PNG metadata and pixels contain the newest job-start revision.
10. Clear the board, save through keyboard and menu paths, reopen, and confirm an empty editable snapshot.
11. Force a save failure and confirm `Save failed` plus the alert; edit again and confirm the stale alert clears.
12. Check light/dark themes and 320, 768, 1024, and 1440 pixel widths.

## Parallelization Opportunities

- Task 1 and Task 3 can be developed independently only in isolated worktrees.
- Task 2 must follow Task 1's `create = true` and `TARGET_EXISTS` contract.
- Task 4 must follow the blank asset and save-controller contracts.
- Task 5 is the composition point and remains serial.
- Documentation can be drafted alongside final read-only validation, but one writer should apply changes.

The default execution remains serial because the feature repeatedly touches `session.lua`, `app.js`, and shared tests. Parallel read-only review and validation are safe.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Same-name race overwrites user data | High | Friendly preflight plus atomic no-replace hard link as the authority; test race injection |
| Failed blank write leaves a blocking partial target | High | Stage and verify in a temporary file; never expose the target before the complete inode is ready |
| Cleanup deletes a replacement target | High | Never roll back through the target path; a replacement makes the commit link fail and remains untouched |
| Filesystem lacks hard-link support | Medium | Fail safely before Markdown insertion and preserve the prior active session |
| Snapshot API changes unnecessarily | Medium | Preserve the existing plain snapshot-object response; initialize `Saved` after successful load |
| Preliminary exports finish out of invocation order | High | Treat callbacks as intents; capture a fresh snapshot and PNG only when each serialized job begins |
| Older save overwrites newer content | High | Serialize job capture and requests; test matching final metadata, pixels, and revision |
| Stale completion lies about state | High | Gate status and alert mutations by attempt and document revision |
| Empty board cannot invoke save callback | Medium | Whole-board host fallback to served blank PNG; test keyboard/menu manual paths |
| Status overlaps existing Quickdraw chrome | Medium | Top-right placement, theme-aware CSS, fixed viewport checks |
| Node checks do not run in CI | Medium | Add built-in Node test command to `make test`, already used by the CI matrix |
| Existing vendored `src/ui.js` does not match the upstream manifest | Low | Do not edit vendor files; require zero new vendor diff and report the pre-existing `cf26d49` mismatch |

## Open Questions

None.
