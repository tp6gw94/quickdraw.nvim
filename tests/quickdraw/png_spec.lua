local bit = require("bit")
local png = require("quickdraw.png")
local is_list = vim.islist or vim.tbl_islist

local function read_fixture()
  local file = assert(io.open("tests/fixtures/blank.png", "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

local function error_code(bytes)
  local snapshot, err = png.extract_snapshot(bytes)
  assert.is_nil(snapshot)
  assert.is_not_nil(err)
  return err.code
end

local function u32(value)
  return string.char(
    bit.band(bit.rshift(value, 24), 0xFF),
    bit.band(bit.rshift(value, 16), 0xFF),
    bit.band(bit.rshift(value, 8), 0xFF),
    bit.band(value, 0xFF)
  )
end

local function read_u32(bytes, offset)
  return ((string.byte(bytes, offset) * 256 + string.byte(bytes, offset + 1)) * 256 + string.byte(bytes, offset + 2))
      * 256
    + string.byte(bytes, offset + 3)
end

local crc_table = {}
for index = 0, 255 do
  local value = index
  for _ = 1, 8 do
    if bit.band(value, 1) ~= 0 then
      value = bit.bxor(bit.rshift(value, 1), 0xEDB88320)
    else
      value = bit.rshift(value, 1)
    end
  end
  crc_table[index] = value
end

local function crc32(bytes)
  local crc = bit.bnot(0)
  for index = 1, #bytes do
    crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, string.byte(bytes, index)), 0xFF)])
  end
  return bit.bnot(crc)
end

local function chunk(chunk_type, data)
  local payload = chunk_type .. data
  return u32(#data) .. payload .. u32(crc32(payload))
end

local function itxt_data(json)
  return "quickdraw.nvim\0\0\0\0\0" .. json
end

local function png_with_chunks(...)
  local fixture = read_fixture()
  return fixture:sub(1, -13) .. table.concat({ ... }) .. fixture:sub(-12)
end

local function metadata_chunk(envelope)
  return chunk("iTXt", itxt_data(vim.json.encode(envelope)))
end

local function metadata_chunks(bytes)
  local chunks = {}
  local position = 9
  while position <= #bytes do
    local length = read_u32(bytes, position)
    local chunk_type = bytes:sub(position + 4, position + 7)
    if chunk_type == "iTXt" then
      chunks[#chunks + 1] = bytes:sub(position + 8, position + 7 + length)
    end
    position = position + length + 12
  end
  return chunks
end

local function png_chunks(bytes)
  local chunks = {}
  local position = 9
  while position <= #bytes do
    local length = read_u32(bytes, position)
    local finish = position + length + 11
    chunks[#chunks + 1] = {
      data = bytes:sub(position + 8, position + 7 + length),
      raw = bytes:sub(position, finish),
      type = bytes:sub(position + 4, position + 7),
    }
    position = finish + 1
  end
  return chunks
end

local function is_quickdraw_chunk(chunk_record)
  return chunk_record.type == "iTXt" and chunk_record.data:sub(1, 15) == "quickdraw.nvim\0"
end

describe("quickdraw PNG parser", function()
  it("accepts a valid PNG without metadata", function()
    local snapshot, err = png.extract_snapshot(read_fixture())

    assert.is_nil(snapshot)
    assert.is_nil(err)
  end)

  it("round-trips a keyed snapshot in an uncompressed Quickdraw iTXt chunk", function()
    local input = read_fixture()
    local expected = { name = "line", points = { { x = 1, y = 2 } } }
    local encoded, embed_err = png.embed_snapshot(input, expected)

    assert.is_not_nil(encoded)
    assert.is_nil(embed_err)
    assert.are.same(expected, select(1, png.extract_snapshot(encoded)))

    local metadata = metadata_chunks(encoded)
    assert.are.equal(1, #metadata)
    assert.are.equal("quickdraw.nvim", metadata[1]:sub(1, 14))
    assert.are.equal("\0\0\0\0\0", metadata[1]:sub(15, 19))
    assert.are.same(
      { schema = "quickdraw.nvim", snapshot = expected, version = 1 },
      vim.json.decode(metadata[1]:sub(20))
    )
  end)

  it("round-trips an empty snapshot as a JSON object", function()
    local encoded, embed_err = png.embed_snapshot(read_fixture(), {})
    assert.is_not_nil(encoded)
    assert.is_nil(embed_err)

    local snapshot, extract_err = png.extract_snapshot(encoded)
    assert.is_nil(extract_err)
    assert.is_false(is_list(snapshot))
    assert.are.same({}, snapshot)
  end)

  it("round-trips Unicode and data URLs", function()
    local expected = {
      image = "data:image/png;base64,iVBORw0KGgo=",
      title = "画笔 ✨",
    }
    local encoded, embed_err = png.embed_snapshot(read_fixture(), expected)

    assert.is_not_nil(encoded)
    assert.is_nil(embed_err)
    assert.are.same(expected, select(1, png.extract_snapshot(encoded)))
  end)

  it("replaces malformed, unsupported, and duplicate Quickdraw chunks", function()
    local input = png_with_chunks(
      chunk("iTXt", "quickdraw.nvim\0"),
      metadata_chunk({ schema = "quickdraw.nvim", snapshot = { stale = true }, version = 2 }),
      metadata_chunk({ schema = "quickdraw.nvim", snapshot = { stale = true }, version = 1 })
    )
    local expected = { fresh = true }

    local encoded, embed_err = png.embed_snapshot(input, expected)

    assert.is_not_nil(encoded)
    assert.is_nil(embed_err)
    local matching = {}
    for _, chunk_record in ipairs(png_chunks(encoded)) do
      if is_quickdraw_chunk(chunk_record) then
        matching[#matching + 1] = chunk_record
      end
    end
    assert.are.equal(1, #matching)
    assert.are.same(expected, select(1, png.extract_snapshot(encoded)))
  end)

  it("preserves unrelated chunks and inserts metadata before IEND", function()
    local input = png_with_chunks(chunk("tEXt", "before"), chunk("iTXt", "other\0\0\0\0\0preserve"))
    local original_chunks = png_chunks(input)
    local original_nonmatching = {}
    for _, chunk_record in ipairs(original_chunks) do
      if not is_quickdraw_chunk(chunk_record) then
        original_nonmatching[#original_nonmatching + 1] = chunk_record.raw
      end
    end

    local original_input = input
    local encoded, embed_err = png.embed_snapshot(input, { preserved = true })

    assert.is_not_nil(encoded)
    assert.is_nil(embed_err)
    assert.are.equal(original_input, input)

    local output_chunks = png_chunks(encoded)
    local output_nonmatching = {}
    for _, chunk_record in ipairs(output_chunks) do
      if not is_quickdraw_chunk(chunk_record) then
        output_nonmatching[#output_nonmatching + 1] = chunk_record.raw
      end
    end
    assert.are.same(original_nonmatching, output_nonmatching)
    assert.is_true(is_quickdraw_chunk(output_chunks[#output_chunks - 1]))
    assert.are.equal("IEND", output_chunks[#output_chunks].type)
  end)

  it("round-trips a snapshot strictly larger than 16 MiB", function()
    local expected = { data = string.rep("x", 16 * 1024 * 1024 + 1) }

    local encoded, embed_err = png.embed_snapshot(read_fixture(), expected)

    assert.is_not_nil(encoded)
    assert.is_nil(embed_err)
    assert.are.same(expected, select(1, png.extract_snapshot(encoded)))
  end)

  it("rejects malformed matching iTXt layout", function()
    local bytes = png_with_chunks(chunk("iTXt", "quickdraw.nvim\0"))
    assert.are.equal("INVALID_METADATA", error_code(bytes))
  end)

  it("rejects malformed metadata JSON", function()
    local bytes = png_with_chunks(chunk("iTXt", itxt_data("{")))
    assert.are.equal("INVALID_METADATA", error_code(bytes))
  end)

  it("rejects a matching iTXt chunk with an invalid compression flag", function()
    local envelope = { schema = "quickdraw.nvim", snapshot = vim.empty_dict(), version = 1 }
    local data = itxt_data(vim.json.encode(envelope))
    data = data:sub(1, 15) .. string.char(1) .. data:sub(17)

    assert.are.equal("INVALID_METADATA", error_code(png_with_chunks(chunk("iTXt", data))))
  end)

  it("rejects invalid metadata schema and object shapes", function()
    local wrong_schema = png_with_chunks(metadata_chunk({ schema = "other", snapshot = {}, version = 1 }))
    assert.are.equal("INVALID_METADATA", error_code(wrong_schema))

    local array_envelope = png_with_chunks(chunk("iTXt", itxt_data("[]")))
    assert.are.equal("INVALID_METADATA", error_code(array_envelope))

    local array_snapshot =
      png_with_chunks(metadata_chunk({ schema = "quickdraw.nvim", snapshot = { "item" }, version = 1 }))
    assert.are.equal("INVALID_METADATA", error_code(array_snapshot))
  end)

  it("rejects unsupported metadata versions", function()
    local bytes = png_with_chunks(metadata_chunk({ schema = "quickdraw.nvim", snapshot = {}, version = 2 }))
    assert.are.equal("UNSUPPORTED_VERSION", error_code(bytes))
  end)

  it("rejects duplicate Quickdraw metadata", function()
    local envelope = { schema = "quickdraw.nvim", snapshot = {}, version = 1 }
    local bytes = png_with_chunks(metadata_chunk(envelope), metadata_chunk(envelope))
    assert.are.equal("DUPLICATE_METADATA", error_code(bytes))
  end)

  it("returns ENCODE_FAILED without a partial output", function()
    local input = read_fixture()
    local output, err = png.embed_snapshot(input, { callback = function() end })

    assert.is_nil(output)
    assert.are.equal("ENCODE_FAILED", err.code)
    assert.are.equal(input, read_fixture())
  end)

  it("uses the standard IEND CRC vector", function()
    local bytes = read_fixture()
    assert.are.same({ 0xAE, 0x42, 0x60, 0x82 }, { string.byte(bytes, -4, -1) })
  end)

  it("rejects an invalid signature", function()
    local bytes = "X" .. read_fixture():sub(2)
    assert.are.equal("INVALID_PNG", error_code(bytes))
  end)

  it("rejects a truncated chunk", function()
    local bytes = read_fixture():sub(1, -2)
    assert.are.equal("INVALID_CHUNK", error_code(bytes))
  end)

  it("rejects a chunk larger than the PNG limit", function()
    local bytes = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
      .. string.char(0x80, 0x00, 0x00, 0x00)
      .. "IHDR"
    assert.are.equal("CHUNK_TOO_LARGE", error_code(bytes))
  end)

  it("rejects a CRC mismatch", function()
    local bytes = read_fixture()
    local crc_offset = #bytes - 3
    local corrupted_crc = string.char((string.byte(bytes, crc_offset) + 1) % 256) .. bytes:sub(crc_offset + 1)
    bytes = bytes:sub(1, crc_offset - 1) .. corrupted_crc

    assert.are.equal("INVALID_CRC", error_code(bytes))
  end)

  it("rejects a missing IEND", function()
    local bytes = read_fixture():sub(1, -13)
    assert.are.equal("INVALID_CHUNK", error_code(bytes))
  end)

  it("rejects a non-empty IEND", function()
    local bytes = read_fixture():sub(1, -13)
      .. string.char(0, 0, 0, 1)
      .. "IEND"
      .. string.char(0)
      .. string.char(0xD1, 0x1A, 0x4F, 0xE1)
    assert.are.equal("INVALID_CHUNK", error_code(bytes))
  end)

  it("rejects bytes after IEND", function()
    assert.are.equal("INVALID_CHUNK", error_code(read_fixture() .. "trailing"))
  end)
end)
