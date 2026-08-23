# Implementation Plan: artifact-format

## Overview

Implement the approved `artifact-format` module from `SPEC-artifact-format.md`: validate PNG structure and CRCs, embed versioned Quickdraw snapshots in uncompressed `iTXt` metadata, extract them with stable errors, and verify behavior across the declared Neovim versions.

This plan excludes commands, paths, HTTP, browser behavior, and the editor UI.

## Dependency Graph

```text
Existing Plenary harness + PNG fixture
                  |
                  v
       PNG structure parser + CRC32
                  |
                  v
       iTXt codec + JSON envelope
                  |
                  v
 replacement + preservation + large payload
                  |
                  v
       formatting and compatibility CI
```

## Architecture Decisions

- Parse Lua binary strings into offset records; preserve original chunk byte ranges and assemble output once with `table.concat`.
- Validate a narrow PNG structural contract: exact signature, first 13-byte `IHDR`, bounded chunks with valid CRCs, and one zero-length final `IEND` with no trailing bytes. Do not validate pixel semantics or decompress `IDAT`.
- Read lengths and stored CRCs with byte arithmetic. Normalize LuaJIT signed CRC32 results before comparison or serialization.
- Match metadata only by an exact NUL-terminated `quickdraw.nvim` keyword in an `iTXt` chunk. Preserve unrelated chunks as opaque bytes.
- Treat embedding as explicit repair: after PNG structure and CRC validation, remove every matching Quickdraw chunk without decoding it and write the current snapshot once. Extraction remains strict.
- Use `vim.islist or vim.tbl_islist` for Neovim-version compatibility and preserve empty JSON-object semantics with `vim.empty_dict()`.
- Keep Tasks 1–3 sequential because they share the same implementation and test files. Parallel writers would add merge risk without shortening the critical path.

## Task List

### Phase 1: Binary foundation

- [ ] Task 1: Implement validated PNG parsing and CRC32

### Checkpoint: Binary foundation

- [ ] Valid PNG without Quickdraw metadata returns `nil, nil`
- [ ] Malformed structure and CRC failures return stable errors
- [ ] Existing tests remain green

### Phase 2: Metadata feature

- [ ] Task 2: Implement Quickdraw iTXt round-trip
- [ ] Task 3: Complete replacement, preservation, and large-payload behavior

### Checkpoint: Metadata feature

- [ ] Embed and extract round-trip representative snapshots
- [ ] Re-embedding leaves exactly one Quickdraw metadata chunk
- [ ] Other chunks and `IDAT` bytes remain unchanged
- [ ] Payload larger than 16 MiB passes

### Phase 3: Project gates

- [ ] Task 4: Enforce formatting and Neovim compatibility in CI

### Checkpoint: Complete

- [ ] `make test` passes
- [ ] `stylua --check lua tests` passes
- [ ] `git diff --check` passes
- [ ] Every success criterion in `SPEC-artifact-format.md` is covered
- [ ] Ready for human review before implementation begins

## Verification Strategy

Every task runs:

```sh
make test
stylua --check lua tests
git diff --check
```

Task 4 additionally verifies that `.github/workflows/lint-test.yml` runs the same test and formatting commands for the declared matrix. A pushed CI run remains external evidence, not part of local completion authority.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| LuaJIT bit operations return signed 32-bit values | High | Normalize to unsigned values and test the known `IEND` CRC `AE426082` |
| Repeated substring copies amplify memory use | High | Store offsets, scan in place, and concatenate output once |
| Empty Lua tables can encode as JSON arrays | High | Normalize empty snapshot objects with `vim.empty_dict()` and test on minimum/current Neovim |
| Current Plenary HEAD may not support Neovim 0.8 | Medium | Add the minimum-version gate; pin only the test dependency if the gate proves it necessary |
| The theoretical 2 GiB chunk limit is impractical to integration-test | Medium | Unit-test the 31-bit arithmetic guard and retain one integration payload just over 16 MiB |
| Pure Lua tests do not prove every desktop viewer accepts the PNG | Low | Preserve standard PNG layout and leave a real-viewer smoke check for editor-session integration |

## Open Questions

None.
