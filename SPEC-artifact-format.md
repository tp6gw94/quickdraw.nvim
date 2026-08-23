# Spec: artifact-format

Module id: `artifact-format`

## Objective

Use Lua to store a Quickdraw snapshot in a PNG `iTXt` chunk so one `.png` remains viewable as an ordinary image and can also be reopened for editing.

This module handles only PNG bytes and metadata. HTTP, browser behavior, and file paths belong to later modules.

## Tech Stack

- Neovim Lua
- Neovim >= 0.8
- Lua binary strings
- `vim.json.encode()` and `vim.json.decode()`
- LuaJIT `bit` library for CRC32
- PNG 1.2 `iTXt` ancillary chunks
- No runtime dependencies

## Metadata Contract

- Chunk type: `iTXt`
- Keyword: `quickdraw.nvim`
- Compression flag: `0`
- Compression method: `0`
- Language tag: empty
- Translated keyword: empty
- Text: UTF-8 JSON

```json
{
  "schema": "quickdraw.nvim",
  "version": 1,
  "snapshot": {}
}
```

Rules:

- `schema` must equal `quickdraw.nvim`.
- `version` must be a supported integer.
- `snapshot` must be a JSON object.
- Metadata must not contain a filename, path, or Markdown document location.
- The plugin imposes no payload-size limit.
- The PNG chunk limit still applies: chunk data cannot exceed `2^31 - 1` bytes. With the `quickdraw.nvim` iTXt fields, the theoretical JSON maximum is 2,147,483,628 bytes.

## Public Interface

```lua
---@param png_bytes string
---@param snapshot table
---@return string? encoded_png
---@return QuickdrawError? error
embed_snapshot(png_bytes, snapshot)

---@param png_bytes string
---@return table? snapshot
---@return QuickdrawError? error
extract_snapshot(png_bytes)
```

Return semantics:

| Result | Snapshot/PNG | Error |
|---|---|---|
| Success | Value | `nil` |
| Ordinary PNG without metadata | `nil` | `nil` |
| Invalid PNG or metadata | `nil` | Error object |

Error shape:

```lua
{
  code = "INVALID_PNG",
  message = "PNG signature is invalid",
}
```

Stable error codes:

- `INVALID_PNG`
- `INVALID_CHUNK`
- `INVALID_CRC`
- `INVALID_METADATA`
- `DUPLICATE_METADATA`
- `UNSUPPORTED_VERSION`
- `CHUNK_TOO_LARGE`
- `ENCODE_FAILED`

## Behavior

### `embed_snapshot`

1. Validate the PNG signature.
2. Parse and validate all chunk boundaries and CRCs.
3. Remove all existing `quickdraw.nvim` chunks without decoding their payloads.
4. Wrap the current snapshot in versioned JSON.
5. Create an uncompressed `iTXt` chunk.
6. Insert the metadata before `IEND`.
7. Return a new Lua binary string.

The input remains unchanged and no partial output is returned on failure. Replacing all matching chunks is deliberate repair behavior: duplicate, malformed, or unsupported Quickdraw payloads are discarded in favor of the current snapshot, but the PNG structure, chunk boundaries, and CRCs must still be valid before rewriting.

### `extract_snapshot`

1. Validate the PNG signature, chunk boundaries, and CRCs.
2. Find `quickdraw.nvim` metadata.
3. Return `nil, nil` if metadata is absent.
4. Return `DUPLICATE_METADATA` if multiple matching chunks exist.
5. Validate the `iTXt` layout, JSON schema, and version.
6. Return the snapshot table.

## Commands

```text
All tests: make test
Format:    stylua lua tests
Lint:      stylua --check lua tests
Build:     none
Dev:       no standalone service for this module
```

## Project Structure

```text
lua/
└── quickdraw/
    └── png.lua

tests/
├── fixtures/
│   └── blank.png
└── quickdraw/
    └── png_spec.lua

CAPABILITIES.md
SPEC-artifact-format.md
```

## Code Style

```lua
local M = {}

function M.extract_snapshot(png_bytes)
  local chunks, err = parse_chunks(png_bytes)
  if not chunks then
    return nil, err
  end

  local metadata = find_metadata(chunks)
  if #metadata == 0 then
    return nil, nil
  end
  if #metadata > 1 then
    return nil, new_error("DUPLICATE_METADATA", "multiple metadata chunks")
  end

  return decode_snapshot(metadata[1])
end

return M
```

Conventions:

- Modules and functions use `snake_case`.
- Constants use `UPPER_SNAKE_CASE`.
- Expected data errors use return values rather than `error()`.
- Helpers remain module-private.
- Do not introduce abstractions used only once.

## Testing Strategy

Use the existing Plenary/Busted environment.

Tests cover:

1. PNG → embed → extract restores the same snapshot.
2. Unicode snapshots round-trip correctly.
3. Snapshots containing data URLs round-trip correctly.
4. A snapshot larger than 16 MiB succeeds, proving there is no former arbitrary limit.
5. Missing metadata returns `nil, nil`.
6. Updating metadata leaves one matching chunk.
7. Other chunks, their order, and `IDAT` bytes remain unchanged.
8. Input PNG bytes remain unchanged.
9. CRC32 generation and validation are correct.
10. Invalid signatures, truncated chunks, bad CRCs, and malformed JSON are rejected.
11. Extraction rejects invalid schemas, unsupported versions, and duplicate metadata.
12. Embedding replaces duplicate, malformed, or unsupported Quickdraw metadata when the PNG structure and CRCs remain valid.
13. Invalid input produces no partial output.

No coverage percentage is required.

## Boundaries

### Always

- Validate PNG signatures, chunk boundaries, CRCs, schema, and version.
- Preserve non-Quickdraw chunks.
- Return a new binary string.
- Use stable error codes.
- Operate completely offline.

### Ask First

- Change the metadata schema.
- Enable iTXt compression.
- Add a runtime dependency.
- Use a custom PNG chunk.
- Add a sidecar file.

### Never

- Guess how to parse an unsupported version.
- Store file paths in metadata.
- Silently accept corrupt or duplicate metadata during extraction.
- Preserve stale Quickdraw metadata when embedding the current snapshot.
- Add an arbitrary plugin payload-size limit.
- Make network requests.

## Success Criteria

- Ordinary image viewers can open the output PNG.
- Lua can restore the complete snapshot from the same PNG.
- No sidecar JSON file is created.
- Updating metadata leaves one `quickdraw.nvim` chunk.
- Non-Quickdraw chunks and image data remain unchanged.
- Metadata larger than 16 MiB passes tests.
- All tests and Stylua checks pass.
- There are no runtime dependencies.

## Open Questions

None.
