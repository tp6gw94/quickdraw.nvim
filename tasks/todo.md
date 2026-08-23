# Tasks: artifact-format

## Task 1: Implement validated PNG parsing and CRC32

**Description:** Create the artifact module, a valid PNG fixture, and the minimum parser needed to safely inspect PNG chunks before any metadata work.

**Acceptance criteria:**

- [x] A valid PNG with first `IHDR`, valid chunk CRCs, and final zero-length `IEND` parses and `extract_snapshot()` returns `nil, nil`.
- [x] Invalid signatures, illegal or truncated lengths, malformed/missing `IEND`, trailing bytes, and CRC mismatches return the specified stable error without a partial value.
- [x] CRC32 handles LuaJIT signed results correctly and passes a fixed known vector including `IEND` CRC `AE426082`.

**Verification:**

- [x] `make test`
- [ ] `stylua --check lua tests` — Stylua is not installed locally.
- [x] `git diff --check`

**Dependencies:** None

**Files likely touched:**

- `lua/quickdraw/png.lua`
- `tests/fixtures/blank.png`
- `tests/quickdraw/png_spec.lua`

**Estimated scope:** Medium — 3 files

## Checkpoint: Binary foundation

- [x] Valid ordinary PNG extraction works.
- [x] Structural and CRC failures are covered.
- [x] Existing template tests remain green.

## Task 2: Implement Quickdraw iTXt round-trip

**Description:** Add exact Quickdraw `iTXt` parsing, versioned JSON envelope validation, and the first complete embed/extract path.

**Acceptance criteria:**

- [ ] Keyed, empty-object, Unicode, and data-URL snapshots embed and extract with the approved schema and uncompressed iTXt layout.
- [ ] Extraction rejects malformed matching iTXt data, malformed JSON, invalid schema/object shape, unsupported versions, and duplicate metadata with stable errors.
- [ ] Encoding failures return `ENCODE_FAILED`; inputs remain unchanged and failures return no partial output.

**Verification:**

- [ ] `make test`
- [ ] `stylua --check lua tests`
- [ ] `git diff --check`

**Dependencies:** Task 1

**Files likely touched:**

- `lua/quickdraw/png.lua`
- `tests/quickdraw/png_spec.lua`

**Estimated scope:** Small — 2 files

## Task 3: Complete replacement, preservation, and large-payload behavior

**Description:** Finish the approved repair semantics and byte-preservation guarantees, then cover the absence of an arbitrary plugin payload limit.

**Acceptance criteria:**

- [ ] Embedding removes all existing matching Quickdraw chunks—including duplicate, malformed, or unsupported payloads—and writes exactly one current snapshot when PNG structure and CRCs are valid.
- [ ] Non-Quickdraw chunks retain their original bytes and relative order, `IDAT` remains byte-identical, metadata is inserted before `IEND`, and the input string is unchanged.
- [ ] One snapshot payload strictly larger than 16 MiB round-trips; the PNG 31-bit chunk guard is enforced without a smaller application limit.

**Verification:**

- [ ] `make test`
- [ ] `stylua --check lua tests`
- [ ] `git diff --check`

**Dependencies:** Task 2

**Files likely touched:**

- `lua/quickdraw/png.lua`
- `tests/quickdraw/png_spec.lua`

**Estimated scope:** Small — 2 files

## Checkpoint: Metadata feature

- [ ] The full public API satisfies the approved return contract.
- [ ] Round-trip, repair, preservation, error, and large-payload tests pass.
- [ ] No runtime dependency or sidecar file was added.

## Task 4: Enforce formatting and Neovim compatibility in CI

**Description:** Make CI enforce the commands and minimum Neovim version declared by the specification.

**Acceptance criteria:**

- [ ] Stylua checks both `lua` and `tests`.
- [ ] The test matrix covers Neovim `v0.8.0`, stable, and nightly while retaining Linux, macOS, and Windows.
- [ ] `make test` passes locally; if current Plenary is incompatible with 0.8, only the test dependency is pinned to a verified compatible revision.

**Verification:**

- [ ] `make test`
- [ ] `stylua --check lua tests`
- [ ] `git diff --check`
- [ ] Manually inspect `.github/workflows/lint-test.yml` for the declared commands and matrix.

**Dependencies:** Task 3

**Files likely touched:**

- `.github/workflows/lint-test.yml`
- `tests/minimal_init.lua` only if a verified test-harness compatibility change is required

**Estimated scope:** Small — 1–2 files

## Checkpoint: Complete

- [ ] All task acceptance criteria pass.
- [ ] All success criteria in `SPEC-artifact-format.md` are represented by tests or an explicit manual check.
- [ ] Human approves the plan before implementation starts.
