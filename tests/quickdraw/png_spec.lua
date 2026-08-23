local png = require("quickdraw.png")

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

describe("quickdraw PNG parser", function()
  it("accepts a valid PNG without metadata", function()
    local snapshot, err = png.extract_snapshot(read_fixture())

    assert.is_nil(snapshot)
    assert.is_nil(err)
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
