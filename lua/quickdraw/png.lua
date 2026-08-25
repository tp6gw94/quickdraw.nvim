local bit = require("bit")

local M = {}

local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local QUICKDRAW_KEYWORD = "quickdraw.nvim"
local ITXT_PREFIX = QUICKDRAW_KEYWORD .. "\0\0\0\0\0"
local MAX_CHUNK_LENGTH = 2147483647
local UINT32_MODULUS = 4294967296
local SUPPORTED_VERSION = 1

local function new_error(code, message)
  return { code = code, message = message }
end

local function to_unsigned(value)
  if value < 0 then
    return value + UINT32_MODULUS
  end
  return value
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

local function crc32(bytes, first, last)
  local crc = bit.bnot(0)
  for index = first, last do
    local byte = string.byte(bytes, index)
    crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, byte), 0xFF)])
  end
  return to_unsigned(bit.bnot(crc))
end

local function write_u32(value)
  return string.char(
    bit.band(bit.rshift(value, 24), 0xFF),
    bit.band(bit.rshift(value, 16), 0xFF),
    bit.band(bit.rshift(value, 8), 0xFF),
    bit.band(value, 0xFF)
  )
end

local function read_u32(bytes, offset)
  local first, second, third, fourth = string.byte(bytes, offset, offset + 3)
  if not fourth then
    return nil
  end
  return ((first * 256 + second) * 256 + third) * 256 + fourth
end

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  return vim.tbl_islist(value)
end

local function make_chunk(chunk_type, data)
  local payload = chunk_type .. data
  return write_u32(#data) .. payload .. write_u32(crc32(payload, 1, #payload))
end

local function valid_chunk_type(chunk_type)
  if #chunk_type ~= 4 then
    return false
  end

  for index = 1, 4 do
    local byte = string.byte(chunk_type, index)
    local uppercase = byte >= string.byte("A") and byte <= string.byte("Z")
    local lowercase = byte >= string.byte("a") and byte <= string.byte("z")
    if not uppercase and not lowercase then
      return false
    end
  end

  return string.byte(chunk_type, 3) <= string.byte("Z")
end

local function parse_chunks(png_bytes)
  if type(png_bytes) ~= "string" or png_bytes:sub(1, #PNG_SIGNATURE) ~= PNG_SIGNATURE then
    return nil, new_error("INVALID_PNG", "PNG signature is invalid")
  end

  local chunks = {}
  local position = #PNG_SIGNATURE + 1
  local total = #png_bytes

  while position <= total do
    if position + 7 > total then
      return nil, new_error("INVALID_CHUNK", "PNG chunk is truncated")
    end

    local length = read_u32(png_bytes, position)
    if length > MAX_CHUNK_LENGTH then
      return nil, new_error("CHUNK_TOO_LARGE", "PNG chunk is too large")
    end

    local chunk_type = png_bytes:sub(position + 4, position + 7)
    if not valid_chunk_type(chunk_type) then
      return nil, new_error("INVALID_CHUNK", "PNG chunk type is invalid")
    end

    local data_start = position + 8
    local data_end = data_start + length - 1
    local crc_start = data_start + length
    local crc_end = crc_start + 3
    if crc_end > total then
      return nil, new_error("INVALID_CHUNK", "PNG chunk is truncated")
    end

    local stored_crc = read_u32(png_bytes, crc_start)
    if crc32(png_bytes, position + 4, data_end) ~= stored_crc then
      return nil, new_error("INVALID_CRC", "PNG chunk CRC is invalid")
    end

    if #chunks == 0 and (chunk_type ~= "IHDR" or length ~= 13) then
      return nil, new_error("INVALID_CHUNK", "PNG must begin with IHDR")
    end
    if chunk_type == "IHDR" and #chunks > 0 then
      return nil, new_error("INVALID_CHUNK", "PNG contains more than one IHDR")
    end

    chunks[#chunks + 1] = {
      data_end = data_end,
      data_start = data_start,
      finish = crc_end,
      length = length,
      start = position,
      type = chunk_type,
    }

    if chunk_type == "IEND" then
      if length ~= 0 or crc_end ~= total then
        return nil, new_error("INVALID_CHUNK", "PNG IEND is invalid")
      end
      return chunks
    end

    position = crc_end + 1
  end

  return nil, new_error("INVALID_CHUNK", "PNG IEND is missing")
end

local function matching_metadata(bytes, chunk)
  if chunk.type ~= "iTXt" then
    return false
  end

  local keyword_end = bytes:find("\0", chunk.data_start, true)
  return keyword_end ~= nil
    and keyword_end <= chunk.data_end
    and bytes:sub(chunk.data_start, keyword_end - 1) == QUICKDRAW_KEYWORD
end

local function decode_metadata(bytes, chunk)
  if chunk.length < #ITXT_PREFIX or bytes:sub(chunk.data_start, chunk.data_start + #ITXT_PREFIX - 1) ~= ITXT_PREFIX then
    return nil, new_error("INVALID_METADATA", "Quickdraw iTXt layout is invalid")
  end

  local json = bytes:sub(chunk.data_start + #ITXT_PREFIX, chunk.data_end)
  local ok, envelope = pcall(vim.json.decode, json)
  if not ok or type(envelope) ~= "table" or is_list(envelope) then
    return nil, new_error("INVALID_METADATA", "Quickdraw metadata JSON is invalid")
  end

  for key in pairs(envelope) do
    if key ~= "schema" and key ~= "version" and key ~= "snapshot" then
      return nil, new_error("INVALID_METADATA", "Quickdraw metadata shape is invalid")
    end
  end

  if envelope.schema ~= QUICKDRAW_KEYWORD or type(envelope.version) ~= "number" then
    return nil, new_error("INVALID_METADATA", "Quickdraw metadata schema is invalid")
  end
  if envelope.version % 1 ~= 0 then
    return nil, new_error("INVALID_METADATA", "Quickdraw metadata version is invalid")
  end
  if envelope.version ~= SUPPORTED_VERSION then
    return nil, new_error("UNSUPPORTED_VERSION", "Quickdraw metadata version is unsupported")
  end
  if type(envelope.snapshot) ~= "table" or is_list(envelope.snapshot) then
    return nil, new_error("INVALID_METADATA", "Quickdraw snapshot shape is invalid")
  end

  return envelope.snapshot, nil
end

local function find_metadata(bytes, chunks)
  local metadata = {}
  for _, chunk in ipairs(chunks) do
    if matching_metadata(bytes, chunk) then
      metadata[#metadata + 1] = chunk
    end
  end
  return metadata
end

local function encode_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return nil, new_error("ENCODE_FAILED", "Quickdraw snapshot could not be encoded")
  end

  if is_list(snapshot) then
    if #snapshot == 0 then
      snapshot = vim.empty_dict()
    else
      return nil, new_error("INVALID_METADATA", "Quickdraw snapshot must be an object")
    end
  end

  local ok, json = pcall(vim.json.encode, {
    schema = QUICKDRAW_KEYWORD,
    snapshot = snapshot,
    version = SUPPORTED_VERSION,
  })
  if not ok or type(json) ~= "string" then
    return nil, new_error("ENCODE_FAILED", "Quickdraw snapshot could not be encoded")
  end

  local data = ITXT_PREFIX .. json
  if #data > MAX_CHUNK_LENGTH then
    return nil, new_error("CHUNK_TOO_LARGE", "PNG chunk is too large")
  end
  return make_chunk("iTXt", data), nil
end

function M.embed_snapshot(png_bytes, snapshot)
  local chunks, parse_err = parse_chunks(png_bytes)
  if not chunks then
    return nil, parse_err
  end

  local metadata, encode_err = encode_snapshot(snapshot)
  if not metadata then
    return nil, encode_err
  end

  local output = { png_bytes:sub(1, #PNG_SIGNATURE) }
  for _, chunk in ipairs(chunks) do
    if chunk.type == "IEND" then
      output[#output + 1] = metadata
    end
    if not matching_metadata(png_bytes, chunk) then
      output[#output + 1] = png_bytes:sub(chunk.start, chunk.finish)
    end
  end
  return table.concat(output), nil
end

function M.extract_snapshot(png_bytes)
  local chunks, parse_err = parse_chunks(png_bytes)
  if not chunks then
    return nil, parse_err
  end

  local metadata = find_metadata(png_bytes, chunks)
  if #metadata == 0 then
    return nil, nil
  end
  if #metadata > 1 then
    return nil, new_error("DUPLICATE_METADATA", "multiple metadata chunks")
  end

  return decode_metadata(png_bytes, metadata[1])
end

return M
