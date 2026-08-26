# Tasks: neovim-integration

## Task 1: Implement configuration and input/path primitives

**Description:** Add the public `require("quickdraw").setup()` module with deterministic default replacement, then implement the minimum private helpers for basename validation, absolute-path classification, document-relative filesystem targets, Markdown destinations, and platform separator normalization. This task does not start sessions or mutate buffers.

**Acceptance criteria:**

- [x] `setup()` defaults to literal `./assets`, accepts one non-empty string `path`, replaces prior configuration from defaults, rejects unknown/invalid input without partial state changes, and does not expand `~`, environment variables, or globs.
- [x] Names accept a safe Unicode basename with optional `.png`, normalize one lowercase suffix, and reject empty/traversal/separator/control/whitespace/Markdown-delimiter input.
- [x] Relative targets derive from the saved Markdown document directory; POSIX, Windows drive, and UNC absolute paths remain absolute, with `/` used for Markdown destinations.

**Verification:**

- [x] RED then GREEN focused tests cover defaults, repeated setup, invalid setup rollback, basename normalization/rejection, and missing document paths.
- [x] Focused tests prove target resolution is unchanged by global, tab-local, and window-local working-directory changes.
- [x] `stylua --check lua tests` and `git diff --check` pass for the touched files.

**Dependencies:** None

**Files likely touched:**

- `lua/quickdraw.lua`
- `tests/quickdraw/integration_spec.lua`

**Estimated scope:** Medium — 2 files

## Task 2: Open a linked PNG under the Markdown cursor

**Description:** Add the constrained current-line inline-image scanner and the edit branch of the command workflow. A local PNG range containing the byte-indexed cursor resolves to one absolute fixed target and delegates all missing/existing/ordinary/invalid PNG behavior to `quickdraw.session.start()`.

**Acceptance criteria:**

- [x] Every cursor byte position from `!` through `)` on `![](path.png)` resolves the same target, including lines containing Unicode before the image.
- [x] Relative link destinations resolve from the saved Markdown document directory; absolute POSIX/drive/UNC destinations remain absolute and do not need to be under configured `path`.
- [x] URI/query/fragment/title/reference/multiline/angle/whitespace/nested forms are not treated as supported edit links and therefore enter the name-prompt branch; session failures leave the buffer unchanged.

**Verification:**

- [x] RED then GREEN focused tests cover multiple images on one line, cursor boundaries, Unicode byte columns, relative and absolute destinations, and rejected forms falling back to the prompt.
- [x] Session fakes assert exactly one absolute `path` and preserve `NOT_QUICKDRAW`, validation, and browser-warning results.
- [x] Existing `tests/quickdraw/session_spec.lua` remains green.

**Dependencies:** Task 1

**Files likely touched:**

- `lua/quickdraw.lua`
- `tests/quickdraw/integration_spec.lua`

**Estimated scope:** Medium — 2 files

## Task 3: Prompt, start, and insert a new drawing

**Description:** Complete the create branch. Capture the originating Markdown buffer/cursor/document/changedtick, prompt through `vim.ui.input()`, validate the returned basename, create the configured directory, start the fixed target session, and insert the image only after startup succeeds.

**Acceptance criteria:**

- [x] Cancellation or empty input is a no-op; invalid names, unnamed/unsaved relative documents, non-modifiable or changed buffers, and directory/session failures notify without modifying text.
- [x] Valid input recursively creates the configured directory, starts one absolute target, and inserts `![](destination.png)` exactly at the captured cursor byte position; generated alt text is always empty.
- [x] Existing Quickdraw targets reopen through the same path; existing ordinary/invalid PNGs retain session rejection and are never overwritten.

**Verification:**

- [x] RED then GREEN focused tests cover prompt cancellation, validation, directory success/failure, asynchronous buffer changes, insert position, and Unicode surrounding text.
- [x] Tests prove insertion occurs after successful session start and not after any failure; browser-launch warning still inserts and retains the URL.
- [x] Focused integration tests and all existing PNG/session tests pass.

**Dependencies:** Tasks 1-2

**Files likely touched:**

- `lua/quickdraw.lua`
- `tests/quickdraw/integration_spec.lua`

**Estimated scope:** Medium — 2 files

## Checkpoint: Core workflow

- [x] Default and configured creation paths are document-relative or absolute exactly as specified.
- [x] Cursor edit and prompted creation both pass only absolute fixed targets to the existing session API.
- [x] Cancelled and failed operations leave buffer and filesystem state unchanged except for a directory created immediately before a later session failure.
- [x] Focused integration tests, existing PNG/session tests, Stylua, and diff checks pass.

## Task 4: Register `:Quickdraw` and finish command notifications

**Description:** Replace the template user command with one argument-free `:Quickdraw` callback and complete the command-boundary notifications. Registration remains automatic through `plugin/quickdraw.lua`; `setup()` stays optional.

**Acceptance criteria:**

- [x] `:Quickdraw` is registered once with `nargs = 0`, requires a Markdown buffer, and dispatches the tested cursor/create workflow.
- [x] Errors and warnings use `vim.notify()` with title `quickdraw.nvim`; generic messages never include the token.
- [x] Browser-launch failure is non-fatal and displays the returned copyable localhost URL while the session stays active.

**Verification:**

- [x] RED then GREEN tests inspect command metadata, reject arguments/non-Markdown buffers, and cover error/warning notification levels and content.
- [x] Headless runtime loading proves the old `MyFirstFunction` command is absent and `Quickdraw` is present once.
- [x] Full tests, Stylua, and diff checks pass.

**Dependencies:** Tasks 1-3

**Files likely touched:**

- `lua/quickdraw.lua`
- `tests/quickdraw/integration_spec.lua`
- `plugin/quickdraw.lua`
- `plugin/plugin_name.lua` — removed

**Estimated scope:** Medium — 4 files

## Task 5: Remove superseded template code and tests

**Description:** Delete the remaining template module and test artifacts after their Quickdraw replacements are green. Do not rename or modify the completed PNG/session modules.

**Acceptance criteria:**

- [x] No runtime or test file requires `plugin_name`, exposes the template greeting API, or references `MyFirstFunction`.
- [x] Quickdraw setup, integration, PNG, and session suites are the only plugin behavior under test.
- [x] Repository search finds no stale template Lua symbols outside historical Git data.

**Verification:**

- [x] `make test` passes after deleting template files.
- [x] `stylua --check lua tests` and `git diff --check` pass.
- [x] `grep`/file inventory confirms the obsolete module and test paths are gone.

**Dependencies:** Task 4

**Files likely touched:**

- `lua/plugin_name.lua` — removed
- `lua/plugin_name/module.lua` — removed
- `tests/plugin_name/plugin_name_spec.lua` — removed

**Estimated scope:** Small — 3 deletions

## Task 6: Replace template documentation and vimdoc branding

**Description:** Write concise installation, setup, create/edit, supported Markdown, path, error, and compatibility documentation; rename the checked-in help file and configure docs generation for `quickdraw`.

**Acceptance criteria:**

- [x] README documents installation, optional setup, `:Quickdraw`, document-relative versus absolute paths, name rules, empty-alt insertion, cursor editing, manual URL fallback, and Neovim >=0.8.
- [x] `doc/quickdraw.txt` exposes matching help tags and no template branding; `doc/my-template-docs.txt` is removed.
- [x] The docs workflow generates `quickdraw` vimdoc rather than `my-template-docs` without changing unrelated release behavior.

**Verification:**

- [x] README examples match `SPEC-neovim-integration.md` and implemented command/config names exactly.
- [x] Vim help opens `:help quickdraw` and `:help :Quickdraw` in a local Neovim runtime check.
- [x] Full tests, Stylua, Node syntax, and diff checks pass.

**Dependencies:** Task 5

**Files likely touched:**

- `README.md`
- `doc/quickdraw.txt`
- `doc/my-template-docs.txt` — removed
- `.github/workflows/docs.yml`

**Estimated scope:** Medium — 4 files

## Checkpoint: Complete neovim-integration

- [x] `make test` passes with no skipped tests.
- [x] `stylua --check lua tests` passes.
- [x] `node --check web/quickdraw/app.js` passes.
- [x] `git diff --check` passes.
- [x] Manual create → draw → save → cursor edit restores the same editable drawing.
- [x] Relative behavior survives working-directory changes; absolute configuration works.
- [x] Browser-launch failure leaves an active session and copyable URL.
- [ ] Linux/macOS/Windows with Neovim 0.8/stable/nightly pass after a permitted commit/push.
- [ ] Human reviews and approves the completed capability.
