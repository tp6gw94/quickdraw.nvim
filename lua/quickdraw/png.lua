local bit = require("bit")

local M = {}

local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local MAX_CHUNK_LENGTH = 2147483647
local UINT32_MODULUS = 4294967296

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

local function read_u32(bytes, offset)
  local first, second, third, fourth = string.byte(bytes, offset, offset + 3)
  if not fourth then
    return nil
  end
  return ((first * 256 + second) * 256 + third) * 256 + fourth
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

function M.extract_snapshot(png_bytes)
  local _, err = parse_chunks(png_bytes)
  if err then
    return nil, err
  end
  return nil, nil
end

return M
