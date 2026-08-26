local bit = require("bit")
local png = require("quickdraw.png")
local state = require("quickdraw.session_state")

local uv = vim.loop
local M = {}

local BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local TOKEN_BYTES = 32
local MAX_REQUEST_LINE = 8192
local MAX_HEADERS = 32768
local MAX_BODY_LENGTH = 2147483647
local IDLE_TIMEOUT_MS = 5000
local TARGET_READ_CHUNK = 65536
local SAVE_FILE_MODE = 384
local CREATION_TEMP_PREFIX = ".quickdraw-create-"
local EDITOR_ASSETS = {
  { route = "/", file = "web/quickdraw/index.html", content_type = "text/html; charset=utf-8" },
  { route = "/app.js", file = "web/quickdraw/app.js", content_type = "text/javascript; charset=utf-8" },
  { route = "/save_status.js", file = "web/quickdraw/save_status.js", content_type = "text/javascript; charset=utf-8" },
  { route = "/app.css", file = "web/quickdraw/app.css", content_type = "text/css; charset=utf-8" },
  { route = "/blank.png", file = "web/quickdraw/blank.png", content_type = "image/png" },
  {
    route = "/vendor/@quickdrawjs/core/src/index.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/index.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/editor.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/editor.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/freehand.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/freehand.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/geometry.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/geometry.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/palette.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/palette.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/shapes.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/shapes.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/store.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/store.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/ui.js",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/ui.js",
    content_type = "text/javascript; charset=utf-8",
  },
  {
    route = "/vendor/@quickdrawjs/core/src/quickdraw.css",
    file = "web/quickdraw/vendor/@quickdrawjs/core/src/quickdraw.css",
    content_type = "text/css; charset=utf-8",
  },
}

local random_source
local save_request
local browser_platform
local browser_spawn
local LIFECYCLE_AUGROUP = "QuickdrawSession"

local DEFAULT_LIFECYCLE_API = {
  create_augroup = function(name, opts)
    return vim.api.nvim_create_augroup(name, opts)
  end,
  create_autocmd = function(event, opts)
    return vim.api.nvim_create_autocmd(event, opts)
  end,
}
local lifecycle_api = DEFAULT_LIFECYCLE_API

local DEFAULT_TARGET_FILE_OPERATIONS = {
  lstat = function(path)
    return uv.fs_lstat(path)
  end,
  open = function(path, flags, mode)
    return uv.fs_open(path, flags, mode)
  end,
  fstat = function(fd)
    return uv.fs_fstat(fd)
  end,
  read = function(fd, length, offset)
    return uv.fs_read(fd, length, offset)
  end,
  close = function(fd)
    return uv.fs_close(fd)
  end,
  temp_open = function(path, flags, mode)
    return uv.fs_open(path, flags, mode)
  end,
  temp_write = function(fd, bytes, offset)
    return uv.fs_write(fd, bytes, offset)
  end,
  temp_fstat = function(fd)
    return uv.fs_fstat(fd)
  end,
  temp_close = function(fd)
    return uv.fs_close(fd)
  end,
  temp_unlink = function(path)
    return uv.fs_unlink(path)
  end,
  temp_rename = function(source, target)
    return uv.fs_rename(source, target)
  end,
  temp_lstat = function(path)
    return uv.fs_lstat(path)
  end,
  create_open = function(path, flags, mode)
    return uv.fs_open(path, flags, mode)
  end,
  create_write = function(fd, bytes, offset)
    return uv.fs_write(fd, bytes, offset)
  end,
  create_fstat = function(fd)
    return uv.fs_fstat(fd)
  end,
  create_close = function(fd)
    return uv.fs_close(fd)
  end,
  create_unlink = function(path)
    return uv.fs_unlink(path)
  end,
  create_lstat = function(path)
    return uv.fs_lstat(path)
  end,
  create_link = function(source, target)
    return uv.fs_link(source, target)
  end,
}
local target_file_operations = DEFAULT_TARGET_FILE_OPERATIONS
local creation_sequence = 0

local STATUS_TEXT = {
  [200] = "OK",
  [400] = "Bad Request",
  [404] = "Not Found",
  [415] = "Unsupported Media Type",
  [408] = "Request Timeout",
  [409] = "Conflict",
  [500] = "Internal Server Error",
}

local function new_error(code, message)
  return { code = code, message = message }
end

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  return vim.tbl_islist(value)
end

local function has_forbidden_control(value)
  for index = 1, #value do
    local byte = string.byte(value, index)
    if (byte < 32 and byte ~= 9) or byte == 127 then
      return true
    end
  end
  return false
end

local function has_lone_line_feed(value)
  for index = 1, #value do
    if string.byte(value, index) == 10 and (index == 1 or string.byte(value, index - 1) ~= 13) then
      return true
    end
  end
  return false
end

local function handle_method(handle, name)
  if not handle then
    return nil
  end
  local ok, method = pcall(function()
    return handle[name]
  end)
  if ok and type(method) == "function" then
    return method
  end
  return nil
end

local function is_closing(handle)
  if not handle then
    return true
  end
  local method = handle_method(handle, "is_closing")
  if not method then
    return false
  end
  local ok, closing = pcall(method, handle)
  return ok and closing or false
end

local function close_handle(handle)
  local method = handle_method(handle, "close")
  if not method or is_closing(handle) then
    return true
  end
  local ok, result = pcall(method, handle)
  return ok and result ~= false
end

local function stop_handle(handle)
  local method = handle_method(handle, "stop")
  if not method then
    return true
  end
  local ok, result = pcall(method, handle)
  return ok and result ~= false
end

local function encode_base64url(bytes)
  local output = {}
  for index = 1, #bytes, 3 do
    local first = string.byte(bytes, index)
    local second = string.byte(bytes, index + 1)
    local third = string.byte(bytes, index + 2)
    local value = bit.bor(bit.lshift(first, 16), bit.lshift(second or 0, 8), third or 0)

    output[#output + 1] =
      BASE64URL_ALPHABET:sub(bit.band(bit.rshift(value, 18), 0x3F) + 1, bit.band(bit.rshift(value, 18), 0x3F) + 1)
    output[#output + 1] =
      BASE64URL_ALPHABET:sub(bit.band(bit.rshift(value, 12), 0x3F) + 1, bit.band(bit.rshift(value, 12), 0x3F) + 1)
    if second then
      output[#output + 1] =
        BASE64URL_ALPHABET:sub(bit.band(bit.rshift(value, 6), 0x3F) + 1, bit.band(bit.rshift(value, 6), 0x3F) + 1)
    end
    if third then
      output[#output + 1] = BASE64URL_ALPHABET:sub(bit.band(value, 0x3F) + 1, bit.band(value, 0x3F) + 1)
    end
  end
  return table.concat(output)
end

local BASE64_VALUES = {}
for index = 1, #BASE64_ALPHABET do
  BASE64_VALUES[BASE64_ALPHABET:sub(index, index)] = index - 1
end

local function decode_base64(value)
  if #value % 4 ~= 0 then
    return nil
  end

  local output = {}
  for index = 1, #value, 4 do
    local first = value:sub(index, index)
    local second = value:sub(index + 1, index + 1)
    local third = value:sub(index + 2, index + 2)
    local fourth = value:sub(index + 3, index + 3)
    local a = BASE64_VALUES[first]
    local b = BASE64_VALUES[second]
    local c = third == "=" and 0 or BASE64_VALUES[third]
    local d = fourth == "=" and 0 or BASE64_VALUES[fourth]
    if a == nil or b == nil or c == nil or d == nil then
      return nil
    end
    if fourth == "=" and third ~= "=" and index + 4 < #value then
      return nil
    end
    if third == "=" and fourth ~= "=" then
      return nil
    end

    local number = bit.bor(bit.lshift(a, 18), bit.lshift(b, 12), bit.lshift(c, 6), d)
    output[#output + 1] = string.char(bit.band(bit.rshift(number, 16), 0xFF))
    if third ~= "=" then
      output[#output + 1] = string.char(bit.band(bit.rshift(number, 8), 0xFF))
    end
    if fourth ~= "=" then
      output[#output + 1] = string.char(bit.band(number, 0xFF))
    end
  end
  return table.concat(output)
end

local function read_unix_random()
  if type(uv.fs_open) ~= "function" or type(uv.fs_read) ~= "function" or type(uv.fs_close) ~= "function" then
    return nil, "filesystem random source unavailable"
  end

  local ok, fd, open_error = pcall(uv.fs_open, "/dev/urandom", "r", 0)
  if not ok or not fd then
    return nil, open_error or "filesystem random source unavailable"
  end

  local read_ok, bytes, read_error = pcall(uv.fs_read, fd, TOKEN_BYTES, -1)
  pcall(uv.fs_close, fd)
  if not read_ok or type(bytes) ~= "string" or #bytes ~= TOKEN_BYTES then
    return nil, read_error or "filesystem random source returned insufficient bytes"
  end
  return bytes
end

local function read_windows_random()
  local command = {
    "powershell",
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    "$r=[Security.Cryptography.RandomNumberGenerator]::Create();$b=New-Object byte[] 32;$r.GetBytes($b);$r.Dispose();[Console]::Write([Convert]::ToBase64String($b))",
  }
  local ok, output = pcall(vim.fn.system, command)
  if not ok or vim.v.shell_error ~= 0 then
    return nil, "platform random source unavailable"
  end

  output = output:gsub("%s+$", "")
  local bytes = decode_base64(output)
  if not bytes or #bytes ~= TOKEN_BYTES then
    return nil, "platform random source returned invalid bytes"
  end
  return bytes
end

local function secure_random_bytes()
  if type(uv.random) == "function" then
    local ok, bytes, random_error = pcall(uv.random, TOKEN_BYTES)
    if ok and type(bytes) == "string" and #bytes == TOKEN_BYTES then
      return bytes
    end
    if random_error == nil then
      random_error = "libuv random source returned invalid bytes"
    end
  end

  if package.config:sub(1, 1) == "/" then
    return read_unix_random()
  end
  return read_windows_random()
end

random_source = secure_random_bytes

local function default_browser_platform()
  local ok, uname = pcall(uv.os_uname)
  if ok and type(uname) == "table" and type(uname.sysname) == "string" then
    return uname.sysname
  end
  return package.config:sub(1, 1) == "\\" and "Windows_NT" or "Linux"
end

local function default_browser_spawn(argv, options)
  return vim.fn.jobstart(argv, options)
end

browser_platform = default_browser_platform
browser_spawn = default_browser_spawn

local function browser_argv(url)
  local ok, platform = pcall(browser_platform)
  if not ok or type(platform) ~= "string" then
    return nil
  end

  platform = platform:lower()
  if platform == "darwin" or platform == "macos" then
    return { "open", url }
  end
  if platform == "linux" then
    return { "xdg-open", url }
  end
  if platform == "windows_nt" or platform == "windows" then
    return { "rundll32.exe", "url.dll,FileProtocolHandler", url }
  end
  return nil
end

local function launch_browser(url)
  local argv = browser_argv(url)
  if not argv or type(browser_spawn) ~= "function" then
    return false, new_error("BROWSER_OPEN_FAILED", "default browser could not be opened")
  end

  local ok, job_id = pcall(browser_spawn, argv, { detach = true })
  if not ok or type(job_id) ~= "number" or job_id <= 0 then
    return false, new_error("BROWSER_OPEN_FAILED", "default browser could not be opened")
  end
  return true, nil
end

local function ensure_lifecycle_autocmd()
  if state.lifecycle_autocmd_registered then
    return true
  end

  local create_augroup = lifecycle_api.create_augroup
  local create_autocmd = lifecycle_api.create_autocmd
  if type(create_augroup) ~= "function" or type(create_autocmd) ~= "function" then
    return false
  end

  local ok, group = pcall(create_augroup, LIFECYCLE_AUGROUP, { clear = true })
  if not ok or not group then
    return false
  end
  local created, autocmd = pcall(create_autocmd, "VimLeavePre", {
    callback = function()
      M.stop()
    end,
    group = group,
  })
  if not created or not autocmd then
    return false
  end
  state.lifecycle_autocmd_registered = true
  return true
end

local function generate_token()
  local ok, bytes, random_error = pcall(random_source)
  if not ok or type(bytes) ~= "string" or #bytes ~= TOKEN_BYTES then
    return nil, new_error("TOKEN_FAILED", "secure session token generation failed")
  end
  local token = encode_base64url(bytes)
  if #token == 0 then
    return nil, new_error("TOKEN_FAILED", "secure session token generation failed")
  end
  return token, random_error
end

local function valid_route_key(key)
  if type(key) ~= "string" then
    return false
  end

  local method, path = key:match("^([A-Z]+) (/.*)$")
  return method ~= nil
    and path:sub(1, 1) == "/"
    and not path:find("\0", 1, true)
    and not path:find("\\", 1, true)
    and not path:find("..", 1, true)
    and not path:find("%", 1, true)
end

local function copy_routes(routes)
  if routes == nil then
    return {}
  end
  if type(routes) ~= "table" then
    return nil, new_error("SERVER_FAILED", "invalid route map")
  end

  local copied = {}
  for key, handler in pairs(routes) do
    if not valid_route_key(key) then
      return nil, new_error("SERVER_FAILED", "invalid route map")
    end
    if type(handler) ~= "function" and type(handler) ~= "table" and type(handler) ~= "string" then
      return nil, new_error("SERVER_FAILED", "invalid route map")
    end
    copied[key] = handler
  end
  return copied
end

local function response_for_handler(handler, request)
  local response = handler
  if type(handler) == "function" then
    local ok, result = pcall(handler, request)
    if not ok then
      io.stderr:write(tostring(result) .. "\n")
      return nil, new_error("INTERNAL_ERROR", "request handler failed")
    end
    response = result
  elseif type(handler) == "string" then
    response = { body = handler }
  end

  if type(response) ~= "table" then
    return nil, new_error("INTERNAL_ERROR", "request handler returned an invalid response")
  end
  local status = response.status or 200
  local body = response.body or ""
  local content_type = response.content_type or "text/plain; charset=utf-8"
  if
    type(status) ~= "number"
    or STATUS_TEXT[status] == nil
    or type(body) ~= "string"
    or type(content_type) ~= "string"
  then
    return nil, new_error("INTERNAL_ERROR", "request handler returned an invalid response")
  end
  if content_type:find("[\r\n]", 1) then
    return nil, new_error("INTERNAL_ERROR", "request handler returned an invalid response")
  end
  return { status = status, body = body, content_type = content_type }
end

local function error_response(code)
  local messages = {
    INTERNAL_ERROR = "internal server error",
    INVALID_MULTIPART = "invalid multipart request",
    INVALID_SNAPSHOT = "invalid snapshot",
    INVALID_PNG = "invalid PNG",
    UNSUPPORTED_MEDIA_TYPE = "unsupported media type",
    INVALID_REQUEST = "invalid request",
    NOT_FOUND = "not found",
    SAVE_FAILED = "unable to save drawing",
    TARGET_CHANGED = "target changed",
    TIMEOUT = "request timeout",
  }
  local statuses = {
    INTERNAL_ERROR = 500,
    NOT_FOUND = 404,
    SAVE_FAILED = 500,
    TARGET_CHANGED = 409,
    TIMEOUT = 408,
    UNSUPPORTED_MEDIA_TYPE = 415,
  }
  local message = messages[code] or "request failed"
  return {
    status = statuses[code] or 400,
    body = vim.json.encode({ error = { code = code, message = message } }),
    content_type = "application/json",
  }
end

local function close_client(state)
  if state.closed then
    return true
  end
  state.closed = true
  state.session.clients[state] = nil
  local cleanup_ok = stop_handle(state.timer)
  cleanup_ok = close_handle(state.timer) and cleanup_ok
  if not is_closing(state.client) then
    local read_stop = handle_method(state.client, "read_stop")
    if read_stop then
      local ok, result = pcall(read_stop, state.client)
      cleanup_ok = (ok and result ~= false) and cleanup_ok
    end
    cleanup_ok = close_handle(state.client) and cleanup_ok
  end
  return cleanup_ok
end

local function send_response(state, response)
  if state.responded or state.closed then
    return
  end
  state.responded = true
  stop_handle(state.timer)

  local reason = STATUS_TEXT[response.status] or "Response"
  local payload = table.concat({
    "HTTP/1.1 ",
    tostring(response.status),
    " ",
    reason,
    "\r\nContent-Type: ",
    response.content_type,
    "\r\nContent-Length: ",
    tostring(#response.body),
    "\r\nConnection: close\r\n",
    "Cache-Control: no-store\r\n",
    "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'none'\r\n",
    "Referrer-Policy: no-referrer\r\n",
    "X-Content-Type-Options: nosniff\r\n\r\n",
    response.body,
  })

  local ok = pcall(state.client.write, state.client, payload, function()
    close_client(state)
  end)
  if not ok then
    close_client(state)
  end
end

local function send_error(state, code)
  send_response(state, error_response(code))
end

local function reset_timeout(state)
  if state.closed or state.responded then
    return
  end
  stop_handle(state.timer)
  state.timer:start(state.session.idle_timeout_ms, 0, function()
    if not state.closed and not state.responded then
      send_error(state, "TIMEOUT")
    end
  end)
end

local function parse_headers(block)
  local delimiter = block:find("\r\n\r\n", 1, true)
  if not delimiter or delimiter + 3 > #block then
    return nil
  end

  local request_line_end = block:find("\r\n", 1, true)
  if not request_line_end or request_line_end - 1 > MAX_REQUEST_LINE then
    return nil
  end

  local request_line = block:sub(1, request_line_end - 1)
  if has_forbidden_control(request_line) then
    return nil
  end
  local method, target, version = request_line:match("^([A-Za-z]+) ([^ \t\r\n]+) (HTTP/1%.1)$")
  if not method or not target or not version then
    return nil
  end

  local headers = {}
  local position = request_line_end + 2
  while position < delimiter do
    local line_end = block:find("\r\n", position, true)
    if not line_end or line_end > delimiter then
      return nil
    end
    local line = block:sub(position, line_end - 1)
    local name, value = line:match("^([A-Za-z][A-Za-z0-9-]*):[ \t]*(.*)$")
    if not name or has_forbidden_control(value) then
      return nil
    end
    value = value:gsub("[ \t]+$", "")
    name = name:lower()
    if headers[name] ~= nil then
      return nil
    end
    headers[name] = value
    position = line_end + 2
  end

  if position ~= delimiter + 2 then
    return nil
  end
  if headers["transfer-encoding"] ~= nil then
    return nil
  end

  local content_length = 0
  if headers["content-length"] ~= nil then
    local value = headers["content-length"]
    if not value:match("^%d+$") then
      return nil
    end
    content_length = tonumber(value)
    if not content_length or content_length > MAX_BODY_LENGTH then
      return nil
    end
  end

  return {
    method = method,
    target = target,
    headers = headers,
    content_length = content_length,
    header_end = delimiter + 3,
  }
end

local function find_route(session, method, target)
  if
    target:find("\0", 1, true)
    or target:find("\\", 1, true)
    or target:find("..", 1, true)
    or target:find("%", 1, true)
  then
    return nil
  end

  local prefix = "/" .. session.token
  if target:sub(1, #prefix) ~= prefix then
    return nil
  end
  local path = target:sub(#prefix + 1)
  if path:sub(1, 1) ~= "/" then
    return nil
  end

  return session.routes[method .. " " .. path], path
end

local function dispatch(state)
  local route = state.route
  local request = {
    method = state.method,
    target = state.target,
    path = state.path,
    headers = state.headers,
    body = table.concat(state.body_chunks),
    session = state.session,
  }
  local response, response_error = response_for_handler(route, request)
  if not response then
    send_error(state, response_error.code)
    return
  end
  send_response(state, response)
end

local function append_body(state, data)
  if state.responded or state.closed then
    return
  end

  local remaining = state.content_length - state.body_received
  if #data > remaining then
    data = data:sub(1, remaining)
  end
  if #data > 0 then
    state.body_chunks[#state.body_chunks + 1] = data
    state.body_received = state.body_received + #data
  end
  if state.body_received == state.content_length then
    dispatch(state)
  end
end

local function consume_headers(state, data)
  local existing_length = #state.header_buffer
  local available = MAX_HEADERS - existing_length
  local candidate_data = data
  if #candidate_data > available then
    candidate_data = candidate_data:sub(1, available)
  end
  local combined = state.header_buffer .. candidate_data
  local delimiter = combined:find("\r\n\r\n", 1, true)
  if delimiter then
    if has_lone_line_feed(combined:sub(1, delimiter + 3)) then
      send_error(state, "INVALID_REQUEST")
      return
    end
  elseif has_lone_line_feed(combined) then
    send_error(state, "INVALID_REQUEST")
    return
  end
  if not delimiter then
    local request_line_end = combined:find("\r\n", 1, true)
    if
      (request_line_end and request_line_end - 1 > MAX_REQUEST_LINE)
      or (not request_line_end and #combined > MAX_REQUEST_LINE)
    then
      send_error(state, "INVALID_REQUEST")
    elseif #data > available then
      send_error(state, "INVALID_REQUEST")
    else
      state.header_buffer = combined
    end
    return
  end
  if delimiter + 3 > MAX_HEADERS then
    send_error(state, "INVALID_REQUEST")
    return
  end

  local parsed = parse_headers(combined)
  if not parsed then
    send_error(state, "INVALID_REQUEST")
    return
  end
  local route, path = find_route(state.session, parsed.method, parsed.target)
  if not route then
    send_error(state, "NOT_FOUND")
    return
  end

  state.header_buffer = nil
  state.headers_done = true
  state.method = parsed.method
  state.target = parsed.target
  state.path = path
  state.headers = parsed.headers
  state.content_length = parsed.content_length
  state.route = route
  state.body_chunks = {}
  state.body_received = 0

  local body_start = delimiter + 4 - existing_length
  append_body(state, data:sub(body_start))
end

local function on_read(state, err, data)
  if state.closed or state.responded then
    return
  end
  if err or not data then
    close_client(state)
    return
  end
  reset_timeout(state)
  if state.headers_done then
    append_body(state, data)
  else
    consume_headers(state, data)
  end
end

local function on_connection(session, err)
  if err or session.stopped or session ~= state.active_session then
    return
  end

  local client = uv.new_tcp()
  if not client then
    return
  end
  local accept_ok, accepted = pcall(session.listener.accept, session.listener, client)
  if not accept_ok or not accepted then
    close_handle(client)
    return
  end

  local timer = uv.new_timer()
  if not timer then
    close_handle(client)
    return
  end
  local state = {
    client = client,
    session = session,
    timer = timer,
    header_buffer = "",
    body_chunks = {},
    body_received = 0,
    closed = false,
    responded = false,
    headers_done = false,
  }
  session.clients[state] = true
  reset_timeout(state)
  local read_ok = pcall(client.read_start, client, function(read_err, data)
    on_read(state, read_err, data)
  end)
  if not read_ok then
    close_client(state)
  end
end

local function close_session(session)
  if session.stopped then
    return true
  end
  session.stopped = true
  if state.active_session == session then
    state.active_session = nil
  end
  session.target_baseline = nil
  local cleanup_ok = stop_handle(session.listener)
  cleanup_ok = close_handle(session.listener) and cleanup_ok
  local clients = {}
  for client_state in pairs(session.clients) do
    clients[#clients + 1] = client_state
  end
  for _, client_state in ipairs(clients) do
    cleanup_ok = close_client(client_state) and cleanup_ok
  end
  session.clients = {}
  session.current_snapshot = nil
  session.target_path = nil
  session.token = nil
  session.port = nil
  session.url = nil
  session.listener = nil
  session.routes = nil
  return cleanup_ok
end

local function resolve_editor_root()
  local index_asset = EDITOR_ASSETS[1].file
  local ok, paths = pcall(vim.api.nvim_get_runtime_file, index_asset, true)
  if not ok or type(paths) ~= "table" or not paths[1] then
    return nil, new_error("SERVER_FAILED", "editor assets unavailable")
  end

  local root = vim.fn.fnamemodify(paths[1], ":p:h:h:h")
  if type(root) ~= "string" or root == "" then
    return nil, new_error("SERVER_FAILED", "editor assets unavailable")
  end
  return root
end

local function read_editor_asset(root, relative_path)
  local file = io.open(root .. "/" .. relative_path, "rb")
  if not file then
    return nil, new_error("SERVER_FAILED", "editor assets unavailable")
  end
  local body = file:read("*a")
  file:close()
  if type(body) ~= "string" then
    return nil, new_error("SERVER_FAILED", "editor assets unavailable")
  end
  return body
end

local function empty_snapshot()
  return { document = { store = vim.empty_dict() } }
end

local function normalize_snapshot(snapshot)
  if type(snapshot) == "table" and is_list(snapshot) and #snapshot == 0 then
    return vim.empty_dict()
  end
  return snapshot
end

local function snapshot_response(session)
  local snapshot = normalize_snapshot(session.current_snapshot or empty_snapshot())
  local ok, body = pcall(vim.json.encode, snapshot)
  if not ok or type(body) ~= "string" then
    return error_response("INTERNAL_ERROR")
  end
  return {
    status = 200,
    body = body,
    content_type = "application/json; charset=utf-8",
  }
end

local function build_editor_routes()
  local root, root_error = resolve_editor_root()
  if not root then
    return nil, root_error
  end

  local routes = {}
  for _, asset in ipairs(EDITOR_ASSETS) do
    local body, read_error = read_editor_asset(root, asset.file)
    if not body then
      return nil, read_error
    end
    routes["GET " .. asset.route] = {
      body = body,
      content_type = asset.content_type,
    }
  end
  routes["GET /api/snapshot"] = function(request)
    return snapshot_response(request.session)
  end
  routes["POST /api/save"] = function(request)
    return save_request(request.session, request)
  end
  return routes
end

local function is_missing_error(error_message)
  return type(error_message) == "string" and error_message:match("^ENOENT") ~= nil
end

local function file_identity(stat)
  if type(stat) ~= "table" or stat.dev == nil or stat.ino == nil then
    return nil
  end
  return { dev = stat.dev, ino = stat.ino }
end

local function same_file_identity(left, right)
  return left ~= nil and right ~= nil and left.dev == right.dev and left.ino == right.ino
end

local function read_failed()
  return new_error("READ_FAILED", "target PNG could not be read")
end

local function operation_succeeded(ok, result, operation_error)
  return ok and operation_error == nil and result ~= false and result ~= nil
end

local function is_exists_error(error_message)
  return type(error_message) == "string" and error_message:match("^EEXIST") ~= nil
end

local function target_exists_error()
  return new_error("TARGET_EXISTS", "A drawing with that name already exists. Choose another name.")
end

local function creation_failed(message)
  return new_error("CREATE_FAILED", message or "blank Quickdraw PNG could not be created")
end

local function creation_temp_path(path)
  creation_sequence = creation_sequence + 1
  return path .. CREATION_TEMP_PREFIX .. tostring(vim.fn.getpid()) .. "-" .. tostring(creation_sequence) .. ".tmp"
end

local function remove_creation_temp(path, expected_identity)
  if type(path) ~= "string" then
    return true
  end

  local current, stat_error = uv.fs_lstat(path)
  if not current then
    return is_missing_error(stat_error)
  end
  if not expected_identity or not same_file_identity(expected_identity, file_identity(current)) then
    return false
  end

  local unlink_function = target_file_operations.create_unlink
  if type(unlink_function) ~= "function" then
    return false
  end
  local unlink_ok, unlink_result, unlink_error = pcall(unlink_function, path)
  if not operation_succeeded(unlink_ok, unlink_result, unlink_error) then
    return false
  end
  return uv.fs_lstat(path) == nil
end

local function close_creation_fd(fd)
  local close_function = target_file_operations.create_close
  local close_ok, close_result, close_error
  if type(close_function) == "function" then
    close_ok, close_result, close_error = pcall(close_function, fd)
    if operation_succeeded(close_ok, close_result, close_error) then
      return true
    end
    if close_function ~= uv.fs_close then
      pcall(uv.fs_close, fd)
    end
    return false
  end

  local fallback_ok, fallback_result, fallback_error = pcall(uv.fs_close, fd)
  return operation_succeeded(fallback_ok, fallback_result, fallback_error)
end

local function require_target_absent(path)
  local lstat_function = target_file_operations.create_lstat
  if type(lstat_function) ~= "function" then
    return nil, creation_failed("target could not be checked")
  end
  local ok, stat, stat_error = pcall(lstat_function, path)
  if not ok then
    return nil, creation_failed("target could not be checked")
  end
  if stat then
    return nil, target_exists_error()
  end
  if not is_missing_error(stat_error) then
    return nil, creation_failed("target could not be checked")
  end
  return true, nil
end

local function stage_blank_target(path)
  local root, root_error = resolve_editor_root()
  if not root then
    return nil, root_error
  end
  local seed, seed_error = read_editor_asset(root, "web/quickdraw/blank.png")
  if not seed then
    return nil, seed_error
  end
  local bytes, embed_error = png.embed_snapshot(seed, empty_snapshot())
  if not bytes then
    return nil, creation_failed(embed_error and embed_error.message)
  end

  local temp_path = creation_temp_path(path)
  local open_function = target_file_operations.create_open
  if type(open_function) ~= "function" then
    return nil, creation_failed("blank Quickdraw PNG could not be opened")
  end
  local open_ok, fd, open_error = pcall(open_function, temp_path, "wx", SAVE_FILE_MODE)
  if not open_ok or fd == nil or open_error ~= nil then
    if fd ~= nil then
      close_creation_fd(fd)
    end
    return nil, creation_failed("blank Quickdraw PNG could not be opened")
  end

  local function fail(message, expected_identity)
    if not expected_identity then
      local fallback_ok, fallback_stat = pcall(uv.fs_fstat, fd)
      expected_identity = fallback_ok and file_identity(fallback_stat) or nil
    end
    close_creation_fd(fd)
    fd = nil
    remove_creation_temp(temp_path, expected_identity)
    return nil, creation_failed(message)
  end

  local write_function = target_file_operations.create_write
  if type(write_function) ~= "function" then
    return fail("blank Quickdraw PNG could not be written")
  end
  local offset = 0
  while offset < #bytes do
    local write_ok, written, write_error = pcall(write_function, fd, bytes:sub(offset + 1), offset)
    if
      not write_ok
      or write_error ~= nil
      or type(written) ~= "number"
      or written % 1 ~= 0
      or written <= 0
      or written > #bytes - offset
    then
      return fail("blank Quickdraw PNG could not be written")
    end
    offset = offset + written
  end

  local fstat_function = target_file_operations.create_fstat
  if type(fstat_function) ~= "function" then
    return fail("blank Quickdraw PNG could not be verified")
  end
  local fstat_ok, stat, fstat_error = pcall(fstat_function, fd)
  local identity = file_identity(stat)
  if
    not fstat_ok
    or fstat_error ~= nil
    or type(stat) ~= "table"
    or stat.type ~= "file"
    or stat.size ~= #bytes
    or not identity
  then
    local fallback_ok, fallback_stat = pcall(uv.fs_fstat, fd)
    local fallback_identity = fallback_ok and file_identity(fallback_stat) or nil
    return fail("blank Quickdraw PNG could not be verified", fallback_identity)
  end

  if not close_creation_fd(fd) then
    fd = nil
    remove_creation_temp(temp_path, identity)
    return nil, creation_failed("blank Quickdraw PNG could not be closed")
  end
  fd = nil

  local lstat_function = target_file_operations.create_lstat
  if type(lstat_function) ~= "function" then
    remove_creation_temp(temp_path, identity)
    return nil, creation_failed("blank Quickdraw PNG could not be verified after closing")
  end
  local lstat_ok, closed_stat, lstat_error = pcall(lstat_function, temp_path)
  if
    not lstat_ok
    or lstat_error ~= nil
    or type(closed_stat) ~= "table"
    or closed_stat.type ~= "file"
    or closed_stat.size ~= #bytes
    or not same_file_identity(identity, file_identity(closed_stat))
  then
    remove_creation_temp(temp_path, identity)
    return nil, creation_failed("blank Quickdraw PNG could not be verified after closing")
  end

  return { path = temp_path, bytes = bytes, identity = identity }, nil
end

local function commit_blank_target(artifact, target)
  local lstat_function = target_file_operations.create_lstat
  if type(lstat_function) ~= "function" then
    remove_creation_temp(artifact.path, artifact.identity)
    return nil, creation_failed("blank Quickdraw PNG could not be verified before commit")
  end
  local lstat_ok, current_stat, lstat_error = pcall(lstat_function, artifact.path)
  if
    not lstat_ok
    or lstat_error ~= nil
    or type(current_stat) ~= "table"
    or current_stat.type ~= "file"
    or current_stat.size ~= #artifact.bytes
    or not same_file_identity(artifact.identity, file_identity(current_stat))
  then
    remove_creation_temp(artifact.path, artifact.identity)
    return nil, creation_failed("blank Quickdraw PNG changed before commit")
  end

  local link_function = target_file_operations.create_link
  if type(link_function) ~= "function" then
    remove_creation_temp(artifact.path, artifact.identity)
    return nil, creation_failed("blank Quickdraw PNG could not be committed")
  end
  local link_ok, link_result, link_error = pcall(link_function, artifact.path, target)
  if not operation_succeeded(link_ok, link_result, link_error) then
    remove_creation_temp(artifact.path, artifact.identity)
    if is_exists_error(link_error) then
      return nil, target_exists_error()
    end
    return nil, creation_failed("blank Quickdraw PNG could not be committed")
  end
  remove_creation_temp(artifact.path, artifact.identity)
  return {
    exists = true,
    dev = artifact.identity.dev,
    ino = artifact.identity.ino,
    size = #artifact.bytes,
    bytes = artifact.bytes,
  },
    nil
end

local function read_target_bytes(path)
  local lstat_function = target_file_operations.lstat
  if type(lstat_function) ~= "function" then
    return nil, read_failed()
  end
  local lstat_ok, stat, stat_error = pcall(lstat_function, path)
  if not lstat_ok then
    return nil, read_failed()
  end
  if not stat then
    if is_missing_error(stat_error) then
      return nil, nil, { exists = false }
    end
    return nil, read_failed()
  end
  if stat.type ~= "file" then
    return nil, read_failed()
  end

  local expected_identity = file_identity(stat)
  if not expected_identity then
    return nil, read_failed()
  end

  local open_function = target_file_operations.open
  if type(open_function) ~= "function" then
    return nil, read_failed()
  end
  local open_ok, fd, open_error = pcall(open_function, path, "r", 0)
  if not open_ok or fd == nil or open_error ~= nil then
    return nil, read_failed()
  end

  local closed = false
  local function close_target()
    if closed then
      return true
    end
    closed = true
    local close_function = target_file_operations.close
    local close_ok, close_result, close_error = pcall(close_function, fd)
    return operation_succeeded(close_ok, close_result, close_error)
  end

  local fstat_function = target_file_operations.fstat
  if type(fstat_function) ~= "function" then
    close_target()
    return nil, read_failed()
  end
  local fstat_ok, opened_stat, fstat_error = pcall(fstat_function, fd)
  if
    not fstat_ok
    or fstat_error ~= nil
    or type(opened_stat) ~= "table"
    or opened_stat.type ~= "file"
    or not same_file_identity(expected_identity, file_identity(opened_stat))
  then
    close_target()
    return nil, read_failed()
  end

  local read_function = target_file_operations.read
  if type(read_function) ~= "function" then
    close_target()
    return nil, read_failed()
  end
  local chunks = {}
  local offset = 0
  while true do
    local read_ok, bytes, read_error = pcall(read_function, fd, TARGET_READ_CHUNK, offset)
    if not read_ok or read_error ~= nil or type(bytes) ~= "string" then
      close_target()
      return nil, read_failed()
    end
    if #bytes == 0 then
      break
    end
    chunks[#chunks + 1] = bytes
    offset = offset + #bytes
  end

  if not close_target() then
    return nil, read_failed()
  end

  local bytes = table.concat(chunks)
  return bytes,
    nil,
    {
      exists = true,
      dev = expected_identity.dev,
      ino = expected_identity.ino,
      size = #bytes,
      bytes = bytes,
    }
end

local function read_target_snapshot(path)
  local bytes, read_error, baseline = read_target_bytes(path)
  if not bytes then
    if read_error then
      return nil, read_error
    end
    return empty_snapshot(), nil, baseline
  end

  local snapshot, parse_error = png.extract_snapshot(bytes)
  if parse_error then
    return nil, parse_error
  end
  if snapshot == nil then
    return nil, new_error("NOT_QUICKDRAW", "target PNG has no Quickdraw metadata")
  end
  return snapshot, nil, baseline
end

local function trim(value)
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_header_parameter(segment)
  local key, raw_value = segment:match("^%s*([A-Za-z0-9-]+)%s*=%s*(.-)%s*$")
  if not key or not raw_value then
    return nil
  end

  local quoted = raw_value:match('^"([^"]*)"$')
  if quoted then
    for index = 1, #quoted do
      local byte = string.byte(quoted, index)
      if byte == 0 or byte == 10 or byte == 13 or byte == 92 then
        return nil
      end
    end
    return key:lower(), quoted
  end
  if raw_value == "" then
    return nil
  end
  local extra = "'()+_.,/:=?-"
  for index = 1, #raw_value do
    local character = raw_value:sub(index, index)
    if not character:match("^[A-Za-z0-9]$") and not extra:find(character, 1, true) then
      return nil
    end
  end
  return key:lower(), raw_value
end

local function parse_parameters(value, expected_type)
  if type(value) ~= "string" or has_forbidden_control(value) then
    return nil
  end
  local base, rest = value:match("^%s*([^;]+)(.*)$")
  if not base or trim(base):lower() ~= expected_type then
    return nil
  end

  local parameters = {}
  local position = 1
  while position <= #rest do
    if rest:sub(position, position) ~= ";" then
      return nil
    end
    local next_separator = rest:find(";", position + 1, true) or (#rest + 1)
    local segment = rest:sub(position + 1, next_separator - 1)
    if trim(segment) == "" then
      return nil
    end
    local key, parameter_value = parse_header_parameter(segment)
    if not key or parameters[key] ~= nil then
      return nil
    end
    parameters[key] = parameter_value
    position = next_separator
  end
  return parameters
end

local function valid_boundary(boundary)
  if type(boundary) ~= "string" or #boundary == 0 or #boundary > 70 then
    return false
  end
  local extra = "'()+_,-./:=?"
  for index = 1, #boundary do
    local character = boundary:sub(index, index)
    if not character:match("^[A-Za-z0-9]$") and not extra:find(character, 1, true) then
      return false
    end
  end
  return true
end

local function parse_multipart_content_type(value)
  local parameters = parse_parameters(value, "multipart/form-data")
  if not parameters or not parameters.boundary or not valid_boundary(parameters.boundary) then
    return nil
  end
  for key in pairs(parameters) do
    if key ~= "boundary" then
      return nil
    end
  end
  return parameters.boundary
end

local function valid_filename(filename)
  return type(filename) == "string"
    and #filename > 0
    and filename ~= "."
    and filename ~= ".."
    and not filename:find("..", 1, true)
    and not filename:find("/", 1, true)
    and not filename:find("\\", 1, true)
    and not filename:find(":", 1, true)
    and not filename:find("%", 1, true)
    and not has_forbidden_control(filename)
end

local function parse_content_disposition(value)
  local parameters = parse_parameters(value, "form-data")
  if not parameters or not parameters.name then
    return nil
  end
  for key in pairs(parameters) do
    if key ~= "name" and key ~= "filename" then
      return nil
    end
  end
  if parameters.name ~= "snapshot" and parameters.name ~= "png" then
    return nil
  end
  if parameters.filename and not valid_filename(parameters.filename) then
    return nil
  end
  if parameters.name == "png" and not parameters.filename then
    return nil
  end
  return parameters.name
end

local function parse_part_headers(block)
  block = block .. "\r\n"
  local headers = {}
  local position = 1
  while position <= #block do
    local line_end = block:find("\r\n", position, true)
    if not line_end then
      return nil
    end
    local line = block:sub(position, line_end - 1)
    local key, value = line:match("^([A-Za-z][A-Za-z0-9-]*):[ \t]*(.*)$")
    if not key or has_forbidden_control(value) then
      return nil
    end
    key = key:lower()
    if headers[key] ~= nil then
      return nil
    end
    headers[key] = trim(value)
    position = line_end + 2
  end
  if headers["content-disposition"] == nil then
    return nil
  end
  if headers["content-type"] == nil then
    return nil, "UNSUPPORTED_MEDIA_TYPE"
  end
  for key in pairs(headers) do
    if key ~= "content-disposition" and key ~= "content-type" then
      return nil
    end
  end
  return headers
end

local function parse_multipart(request)
  local request_content_type = request.headers["content-type"]
  local media_type = type(request_content_type) == "string" and request_content_type:match("^%s*([^;]+)")
  if not media_type or trim(media_type):lower() ~= "multipart/form-data" then
    return nil, new_error("UNSUPPORTED_MEDIA_TYPE", "unsupported media type")
  end

  local boundary = parse_multipart_content_type(request_content_type)
  if not boundary then
    return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
  end

  local body = request.body
  local marker = "--" .. boundary
  if body:sub(1, #marker) ~= marker then
    return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
  end
  local position = #marker + 1
  if body:sub(position, position + 1) ~= "\r\n" then
    return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
  end
  position = position + 2

  local parts = {}
  local finished = false
  while not finished do
    local header_end = body:find("\r\n\r\n", position, true)
    if not header_end or header_end - position > MAX_HEADERS then
      return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
    end
    local headers, headers_error = parse_part_headers(body:sub(position, header_end - 1))
    if not headers then
      return nil,
        new_error(
          headers_error or "INVALID_MULTIPART",
          headers_error == "UNSUPPORTED_MEDIA_TYPE" and "unsupported media type" or "invalid multipart request"
        )
    end

    local data_start = header_end + 4
    local search = data_start
    local data_end
    while true do
      local delimiter = body:find("\r\n" .. marker, search, true)
      if not delimiter then
        return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
      end
      local suffix = delimiter + 2 + #marker
      local next_bytes = body:sub(suffix, suffix + 1)
      if next_bytes == "\r\n" then
        data_end = delimiter - 1
        position = suffix + 2
        break
      end
      if next_bytes == "--" then
        local close_end = suffix + 2
        if close_end == #body + 1 then
          data_end = delimiter - 1
          finished = true
          break
        end
        if close_end + 1 == #body and body:sub(close_end, close_end + 1) == "\r\n" then
          data_end = delimiter - 1
          finished = true
          break
        end
      end
      search = delimiter + 2
    end

    local name = parse_content_disposition(headers["content-disposition"])
    if not name then
      return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
    end
    local content_type = headers["content-type"]:lower()
    if
      (name == "snapshot" and content_type ~= "application/json") or (name == "png" and content_type ~= "image/png")
    then
      return nil, new_error("UNSUPPORTED_MEDIA_TYPE", "unsupported media type")
    end
    if parts[name] ~= nil then
      return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
    end
    parts[name] = body:sub(data_start, data_end)
  end

  if parts.snapshot == nil or parts.png == nil then
    return nil, new_error("INVALID_MULTIPART", "invalid multipart request")
  end
  return parts
end

local function decode_save_request(request)
  local parts, multipart_error = parse_multipart(request)
  if not parts then
    return nil, nil, multipart_error
  end

  local ok, snapshot = pcall(vim.json.decode, parts.snapshot)
  if not ok or type(snapshot) ~= "table" or is_list(snapshot) then
    return nil, nil, new_error("INVALID_SNAPSHOT", "invalid snapshot")
  end
  return snapshot, parts.png, nil
end

local function target_matches_baseline(session)
  local baseline = session.target_baseline
  if type(baseline) ~= "table" or type(session.target_path) ~= "string" then
    return false
  end
  local bytes, read_error, current = read_target_bytes(session.target_path)
  if not current then
    return false
  end
  if not baseline.exists then
    return not current.exists and bytes == nil
  end
  return current.exists
    and same_file_identity(baseline, current)
    and type(bytes) == "string"
    and bytes == baseline.bytes
end

local function temp_path_for(session)
  session.save_sequence = (session.save_sequence or 0) + 1
  return session.target_path
    .. ".quickdraw-"
    .. tostring(vim.fn.getpid())
    .. "-"
    .. tostring(session.save_sequence)
    .. ".tmp"
end

local function unlink_temp(path)
  local unlink_function = target_file_operations.temp_unlink
  if type(unlink_function) == "function" then
    pcall(unlink_function, path)
  end
end

local function write_target(session, bytes)
  if not target_matches_baseline(session) then
    return nil, new_error("TARGET_CHANGED", "target changed")
  end

  local temp_path = temp_path_for(session)
  local open_function = target_file_operations.temp_open
  if type(open_function) ~= "function" then
    return nil, new_error("SAVE_FAILED", "unable to save drawing")
  end
  local open_ok, fd, open_error = pcall(open_function, temp_path, "wx", SAVE_FILE_MODE)
  if not open_ok or fd == nil or open_error ~= nil then
    return nil, new_error("SAVE_FAILED", "unable to save drawing")
  end

  local created = true
  local function fail(error_code)
    local close_function = target_file_operations.temp_close
    if type(close_function) == "function" then
      pcall(close_function, fd)
    end
    if created then
      unlink_temp(temp_path)
    end
    return nil, new_error(error_code, error_code == "TARGET_CHANGED" and "target changed" or "unable to save drawing")
  end

  local write_function = target_file_operations.temp_write
  if type(write_function) ~= "function" then
    return fail("SAVE_FAILED")
  end
  local offset = 0
  while offset < #bytes do
    local write_ok, written, write_error = pcall(write_function, fd, bytes:sub(offset + 1), offset)
    if
      not write_ok
      or write_error ~= nil
      or type(written) ~= "number"
      or written % 1 ~= 0
      or written <= 0
      or written > #bytes - offset
    then
      return fail("SAVE_FAILED")
    end
    offset = offset + written
  end

  local fstat_function = target_file_operations.temp_fstat
  if type(fstat_function) ~= "function" then
    return fail("SAVE_FAILED")
  end
  local fstat_ok, stat, fstat_error = pcall(fstat_function, fd)
  local identity = file_identity(stat)
  if
    not fstat_ok
    or fstat_error ~= nil
    or type(stat) ~= "table"
    or stat.type ~= "file"
    or stat.size ~= #bytes
    or not identity
  then
    return fail("SAVE_FAILED")
  end

  local close_function = target_file_operations.temp_close
  if type(close_function) ~= "function" then
    return fail("SAVE_FAILED")
  end
  local close_ok, close_result, close_error = pcall(close_function, fd)
  fd = nil
  if not operation_succeeded(close_ok, close_result, close_error) then
    if created then
      unlink_temp(temp_path)
    end
    return nil, new_error("SAVE_FAILED", "unable to save drawing")
  end

  if not target_matches_baseline(session) then
    if created then
      unlink_temp(temp_path)
    end
    return nil, new_error("TARGET_CHANGED", "target changed")
  end

  local lstat_function = target_file_operations.temp_lstat
  local lstat_ok, closed_stat, lstat_error
  if type(lstat_function) == "function" then
    lstat_ok, closed_stat, lstat_error = pcall(lstat_function, temp_path)
  end
  if
    not lstat_ok
    or lstat_error ~= nil
    or type(closed_stat) ~= "table"
    or closed_stat.type ~= "file"
    or closed_stat.size ~= #bytes
    or not same_file_identity(identity, file_identity(closed_stat))
  then
    unlink_temp(temp_path)
    return nil, new_error("SAVE_FAILED", "unable to save drawing")
  end

  local rename_function = target_file_operations.temp_rename
  if type(rename_function) ~= "function" then
    unlink_temp(temp_path)
    return nil, new_error("SAVE_FAILED", "unable to save drawing")
  end
  local rename_ok, rename_result, rename_error = pcall(rename_function, temp_path, session.target_path)
  if not operation_succeeded(rename_ok, rename_result, rename_error) then
    unlink_temp(temp_path)
    return nil, new_error("SAVE_FAILED", "unable to save drawing")
  end
  created = false
  session.target_baseline = {
    exists = true,
    dev = identity.dev,
    ino = identity.ino,
    size = #bytes,
    bytes = bytes,
  }
  return true, nil
end

save_request = function(session, request)
  if not session or session.stopped then
    return error_response("SAVE_FAILED")
  end
  local snapshot, png_bytes, decode_error = decode_save_request(request)
  if decode_error then
    return error_response(decode_error.code)
  end
  local embedded, embed_error = png.embed_snapshot(png_bytes, snapshot)
  if not embedded then
    local code = embed_error and embed_error.code or "INVALID_PNG"
    if code == "ENCODE_FAILED" then
      code = "INVALID_SNAPSHOT"
    end
    return error_response(code)
  end
  local saved, save_error = write_target(session, embedded)
  if not saved then
    return error_response(save_error.code)
  end
  session.current_snapshot = normalize_snapshot(snapshot)
  return {
    status = 200,
    body = vim.json.encode({ ok = true }),
    content_type = "application/json",
  }
end

local function validate_target_path(path)
  if type(path) ~= "string" or path == "" or has_forbidden_control(path) or path:find("\0", 1, true) then
    return nil, new_error("INVALID_PATH", "absolute PNG path required")
  end

  local separator = package.config:sub(1, 1)
  local absolute = separator == "\\" and (path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil)
    or separator ~= "\\" and path:sub(1, 1) == "/"
  if not absolute or path:lower():sub(-4) ~= ".png" then
    return nil, new_error("INVALID_PATH", "absolute PNG path required")
  end
  return path
end

local function start_server(options)
  options = options or {}
  if type(options) ~= "table" then
    return nil, new_error("SERVER_FAILED", "invalid session options")
  end
  local previous_session = state.active_session
  local routes, route_error = copy_routes(options.routes)
  if not routes then
    return nil, route_error
  end
  local token, token_error = generate_token()
  if not token then
    return nil, token_error
  end

  local listener = uv.new_tcp()
  if not listener then
    return nil, new_error("SERVER_FAILED", "listener unavailable")
  end
  local session = {
    idle_timeout_ms = options.idle_timeout_ms or IDLE_TIMEOUT_MS,
    listener = listener,
    routes = routes,
    token = token,
    target_path = options.target_path,
    target_baseline = options.target_baseline,
    current_snapshot = options.current_snapshot,
    clients = {},
    stopped = false,
  }
  local bound, bind_error = listener:bind("127.0.0.1", 0)
  if not bound then
    close_session(session)
    return nil, new_error("SERVER_FAILED", "listener bind failed")
  end
  local listening, listen_error = listener:listen(128, function(err)
    on_connection(session, err)
  end)
  if not listening then
    close_session(session)
    return nil, new_error("SERVER_FAILED", "listener setup failed")
  end
  local address = listener:getsockname()
  if not address or not address.port then
    close_session(session)
    return nil, new_error("SERVER_FAILED", "listener address unavailable")
  end

  session.port = address.port
  session.url = "http://127.0.0.1:" .. tostring(address.port) .. "/" .. token .. "/"
  if options.activate ~= false then
    state.active_session = session
    if previous_session then
      close_session(previous_session)
    end
  end
  return {
    host = "127.0.0.1",
    port = address.port,
    token = token,
    url = session.url,
  }, nil, session
end

function M.start(options)
  if type(options) ~= "table" then
    return nil, new_error("INVALID_PATH", "absolute PNG path required")
  end

  local path, path_error = validate_target_path(options.path)
  if not path then
    return nil, path_error
  end

  local snapshot
  local baseline
  local create_requested = options.create == true
  if create_requested then
    local absent, absent_error = require_target_absent(path)
    if not absent then
      return nil, absent_error
    end
    snapshot = empty_snapshot()
  else
    local snapshot_error
    snapshot, snapshot_error, baseline = read_target_snapshot(path)
    if not snapshot then
      return nil, snapshot_error
    end
  end

  local needs_creation = not baseline or not baseline.exists
  local routes, routes_error = build_editor_routes()
  if not routes then
    return nil, routes_error
  end

  if not ensure_lifecycle_autocmd() then
    return nil, new_error("SERVER_FAILED", "session lifecycle unavailable")
  end

  local info, server_error, prepared_session = start_server({
    routes = routes,
    target_path = path,
    target_baseline = baseline,
    current_snapshot = snapshot,
    activate = not needs_creation,
  })
  if not info then
    return nil, server_error
  end

  if needs_creation then
    local staged, stage_error = stage_blank_target(path)
    if not staged then
      close_session(prepared_session)
      return nil, stage_error
    end

    local created_baseline, create_error = commit_blank_target(staged, path)
    if not created_baseline then
      close_session(prepared_session)
      return nil, create_error
    end
    prepared_session.target_baseline = created_baseline
    local previous_session = state.active_session
    state.active_session = prepared_session
    if previous_session then
      close_session(previous_session)
    end
  end

  local browser_opened, warning = launch_browser(info.url)
  return {
    url = info.url,
    path = path,
    browser_opened = browser_opened,
    warning = warning,
  }, nil
end

function M.stop()
  local session = state.active_session
  if not session then
    return true, nil
  end
  if close_session(session) then
    return true, nil
  end
  return nil, new_error("SERVER_FAILED", "session cleanup failed")
end

M._test = {
  default_idle_timeout_ms = function()
    return IDLE_TIMEOUT_MS
  end,
  reset = function()
    random_source = secure_random_bytes
    target_file_operations = DEFAULT_TARGET_FILE_OPERATIONS
    creation_sequence = 0
    browser_platform = default_browser_platform
    browser_spawn = default_browser_spawn
    lifecycle_api = DEFAULT_LIFECYCLE_API
    state.lifecycle_autocmd_registered = false
  end,
  set_random_source = function(source)
    random_source = source
  end,
  set_lifecycle_api = function(api)
    api = api or {}
    lifecycle_api = {
      create_augroup = api.create_augroup or DEFAULT_LIFECYCLE_API.create_augroup,
      create_autocmd = api.create_autocmd or DEFAULT_LIFECYCLE_API.create_autocmd,
    }
    state.lifecycle_autocmd_registered = false
  end,
  set_active_session = function(session)
    state.active_session = session
  end,
  set_browser_launcher = function(launcher)
    launcher = launcher or {}
    if type(launcher.platform) == "function" then
      browser_platform = launcher.platform
    elseif type(launcher.platform) == "string" then
      browser_platform = function()
        return launcher.platform
      end
    else
      browser_platform = default_browser_platform
    end
    if launcher.spawn == false then
      browser_spawn = nil
    elseif type(launcher.spawn) == "function" then
      browser_spawn = launcher.spawn
    else
      browser_spawn = default_browser_spawn
    end
  end,
  set_target_file_operations = function(operations)
    operations = operations or {}
    target_file_operations = {
      lstat = operations.lstat or DEFAULT_TARGET_FILE_OPERATIONS.lstat,
      open = operations.open or DEFAULT_TARGET_FILE_OPERATIONS.open,
      fstat = operations.fstat or DEFAULT_TARGET_FILE_OPERATIONS.fstat,
      read = operations.read or DEFAULT_TARGET_FILE_OPERATIONS.read,
      close = operations.close or DEFAULT_TARGET_FILE_OPERATIONS.close,
      temp_open = operations.temp_open or DEFAULT_TARGET_FILE_OPERATIONS.temp_open,
      temp_write = operations.temp_write or DEFAULT_TARGET_FILE_OPERATIONS.temp_write,
      temp_fstat = operations.temp_fstat or DEFAULT_TARGET_FILE_OPERATIONS.temp_fstat,
      temp_close = operations.temp_close or DEFAULT_TARGET_FILE_OPERATIONS.temp_close,
      temp_unlink = operations.temp_unlink or DEFAULT_TARGET_FILE_OPERATIONS.temp_unlink,
      temp_rename = operations.temp_rename or DEFAULT_TARGET_FILE_OPERATIONS.temp_rename,
      temp_lstat = operations.temp_lstat or DEFAULT_TARGET_FILE_OPERATIONS.temp_lstat,
      create_open = operations.create_open or DEFAULT_TARGET_FILE_OPERATIONS.create_open,
      create_write = operations.create_write or DEFAULT_TARGET_FILE_OPERATIONS.create_write,
      create_fstat = operations.create_fstat or DEFAULT_TARGET_FILE_OPERATIONS.create_fstat,
      create_close = operations.create_close or DEFAULT_TARGET_FILE_OPERATIONS.create_close,
      create_unlink = operations.create_unlink or DEFAULT_TARGET_FILE_OPERATIONS.create_unlink,
      create_lstat = operations.create_lstat or DEFAULT_TARGET_FILE_OPERATIONS.create_lstat,
      create_link = operations.create_link or DEFAULT_TARGET_FILE_OPERATIONS.create_link,
    }
  end,
  get_target_baseline = function()
    return state.active_session and state.active_session.target_baseline
  end,
  get_current_snapshot = function()
    return state.active_session and state.active_session.current_snapshot
  end,
  get_active_token = function()
    return state.active_session and state.active_session.token
  end,
  start = start_server,
}

return M
