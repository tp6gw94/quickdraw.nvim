local session = require("quickdraw.session")
local png = require("quickdraw.png")
local bit = require("bit")
local uv = vim.loop
local is_list = vim.islist or vim.tbl_islist

local function wait_for(predicate, timeout)
  local result = vim.wait(timeout or 3000, predicate, 10)
  assert(result == true or result == 1, "timed out waiting for socket activity")
end

local function parse_response(response)
  local status, headers, body = response:match("^HTTP/1%.1 (%d+) [^\r\n]*\r\n(.-)\r\n\r\n(.*)$")
  assert.is_not_nil(status, response)
  return tonumber(status), headers, body
end

local function header_value(headers, name)
  name = name:lower()
  for line in headers:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:]+):[ \t]*(.*)$")
    if key and key:lower() == name then
      return value
    end
  end
end

local function endpoint(info)
  local host, port, token = info.host, info.port, info.token
  if not host then
    host, port, token = info.url:match("^http://([^:/]+):(%d+)/([^/]+)/$")
  end
  assert.is_not_nil(host)
  assert.is_not_nil(port)
  assert.is_not_nil(token)
  return host, tonumber(port), token
end

local function session_token(info)
  local _, _, token = endpoint(info)
  return token
end

local function request(info, parts, timeout, delay_ms, ignore_write_errors)
  local host, port = endpoint(info)
  local client = uv.new_tcp()
  local response
  local connect_error
  local read_error
  local chunks = {}
  local index = 0
  delay_ms = delay_ms or 20

  local function send_next()
    index = index + 1
    if not parts[index] or client:is_closing() then
      return
    end
    client:write(parts[index], function(err)
      if err and not ignore_write_errors then
        read_error = err
        return
      end
      vim.defer_fn(send_next, delay_ms)
    end)
  end

  client:connect(host, port, function(err)
    if err then
      connect_error = err
      return
    end
    client:read_start(function(err2, data)
      if err2 then
        read_error = err2
      elseif data then
        chunks[#chunks + 1] = data
      else
        response = table.concat(chunks)
        if not client:is_closing() then
          client:close()
        end
      end
    end)
    send_next()
  end)

  wait_for(function()
    return response ~= nil or connect_error ~= nil or read_error ~= nil
  end, timeout)
  assert.is_nil(connect_error)
  assert.is_nil(read_error)
  assert.is_not_nil(response)
  return parse_response(response)
end

local function assert_connection_rejected(info)
  local host, port = endpoint(info)
  local client = uv.new_tcp()
  local done = false
  local connect_error
  client:connect(host, port, function(err)
    done = true
    connect_error = err
    if not client:is_closing() then
      client:close()
    end
  end)
  wait_for(function()
    return done
  end, 1000)
  assert.is_not_nil(connect_error)
end

local function idle_request(info, timeout)
  local host, port = endpoint(info)
  local client = uv.new_tcp()
  local response
  local connect_error
  local read_error
  local chunks = {}

  client:connect(host, port, function(err)
    if err then
      connect_error = err
      return
    end
    client:read_start(function(err2, data)
      if err2 then
        read_error = err2
      elseif data then
        chunks[#chunks + 1] = data
      else
        response = table.concat(chunks)
        if not client:is_closing() then
          client:close()
        end
      end
    end)
  end)

  wait_for(function()
    return response ~= nil or connect_error ~= nil or read_error ~= nil
  end, timeout or 6500)
  assert.is_nil(connect_error)
  assert.is_nil(read_error)
  assert.is_not_nil(response)
  return parse_response(response)
end

local function start(routes, options)
  options = options or {}
  options.routes = routes
  local info, err = session._test.start(options)
  assert.is_nil(err)
  assert.is_not_nil(info)
  return info
end

local function request_for(info, method, target, headers, body, fragments, delay_ms, ignore_write_errors)
  local request_line = method .. " " .. target .. " HTTP/1.1\r\n"
  local header_text = ""
  for name, value in pairs(headers or {}) do
    header_text = header_text .. name .. ": " .. value .. "\r\n"
  end
  local raw = request_line .. header_text .. "\r\n" .. (body or "")
  local parts
  if type(fragments) == "table" then
    parts = fragments
  elseif fragments then
    parts = { raw:sub(1, fragments), raw:sub(fragments + 1) }
  else
    parts = { raw }
  end
  return request(info, parts, nil, delay_ms, ignore_write_errors)
end

local function read_binary(path)
  local file = assert(io.open(path, "rb"))
  local bytes = assert(file:read("*a"))
  assert(file:close())
  return bytes
end

local function write_binary(path, bytes)
  local file = assert(io.open(path, "wb"))
  assert(file:write(bytes))
  assert(file:close())
end

local function write_u32(value)
  return string.char(
    bit.band(bit.rshift(value, 24), 0xFF),
    bit.band(bit.rshift(value, 16), 0xFF),
    bit.band(bit.rshift(value, 8), 0xFF),
    bit.band(value, 0xFF)
  )
end

local function crc32(bytes)
  local crc = bit.bnot(0)
  for index = 1, #bytes do
    local value = bit.band(bit.bxor(crc, string.byte(bytes, index)), 0xFF)
    for _ = 1, 8 do
      if bit.band(value, 1) ~= 0 then
        value = bit.bxor(bit.rshift(value, 1), 0xEDB88320)
      else
        value = bit.rshift(value, 1)
      end
    end
    crc = bit.bxor(bit.rshift(crc, 8), value)
  end
  return bit.band(bit.bnot(crc), 0xFFFFFFFF)
end

local function add_text_chunk(png_bytes, text)
  local payload = "comment\0" .. text
  local chunk_data = "tEXt" .. payload
  local chunk = write_u32(#payload) .. chunk_data .. write_u32(crc32(chunk_data))
  return png_bytes:sub(1, -13) .. chunk .. png_bytes:sub(-12)
end

local function empty_snapshot()
  return { document = { store = vim.empty_dict() } }
end

local function embedded_png(snapshot)
  local encoded, err = png.embed_snapshot(read_binary("tests/fixtures/blank.png"), snapshot)
  assert.is_nil(err)
  return encoded
end

local function creation_temp_paths(path)
  local directory = vim.fn.fnamemodify(path, ":h")
  local filename = vim.fn.fnamemodify(path, ":t")
  return vim.fn.globpath(directory, filename .. ".quickdraw-create-*", false, true)
end

local fake_browser

local function install_fake_browser()
  fake_browser = { platform = "Linux", result = 1, calls = {} }
  session._test.set_browser_launcher({
    platform = function()
      return fake_browser.platform
    end,
    spawn = function(argv, options)
      fake_browser.calls[#fake_browser.calls + 1] = { argv = vim.deepcopy(argv), options = options }
      if fake_browser.throw then
        error("spawn failed")
      end
      return fake_browser.result
    end,
  })
end

local function start_existing_session(snapshot)
  local path = vim.fn.tempname() .. ".png"
  write_binary(path, embedded_png(snapshot))
  local info, err = session.start({ path = path })
  assert.is_nil(err)
  assert.is_not_nil(info)
  return info, path
end

local function get_snapshot(info)
  local status, _, body = request_for(info, "GET", "/" .. session_token(info) .. "/api/snapshot", {}, "")
  assert.are.equal(200, status)
  return vim.json.decode(body)
end

local function multipart_body(boundary, parts)
  local chunks = {}
  for _, part in ipairs(parts) do
    chunks[#chunks + 1] = "--" .. boundary .. "\r\n"
    chunks[#chunks + 1] = "Content-Disposition: " .. part.disposition .. "\r\n"
    chunks[#chunks + 1] = "Content-Type: " .. part.content_type .. "\r\n"
    chunks[#chunks + 1] = "\r\n"
    chunks[#chunks + 1] = part.body
    chunks[#chunks + 1] = "\r\n"
  end
  chunks[#chunks + 1] = "--" .. boundary .. "--\r\n"
  return table.concat(chunks)
end

local function save_request(info, body, content_type)
  return request_for(info, "POST", "/" .. session_token(info) .. "/api/save", {
    ["Content-Length"] = tostring(#body),
    ["Content-Type"] = content_type,
  }, body)
end

local function start_blank_session()
  local path = vim.fn.tempname() .. ".png"
  os.remove(path)
  local info, err = session.start({ path = path })
  assert.is_nil(err)
  assert.is_not_nil(info)
  return info, path
end

describe("quickdraw session HTTP foundation", function()
  before_each(function()
    session._test.reset()
    install_fake_browser()
  end)

  after_each(function()
    session.stop()
    session._test.reset()
  end)

  it("binds an ephemeral loopback listener and generates a URL-safe token", function()
    local info = start({
      ["GET /echo"] = function()
        return { body = "ok", content_type = "text/plain" }
      end,
    })

    assert.is_function(session.start)
    assert.are.equal("127.0.0.1", info.host)
    assert.is_true(info.port > 0)
    assert.matches("^http://127%.0%.0%.1:%d+/[A-Za-z0-9_-]+/$", info.url)
    assert.are.equal(43, #info.token)
    assert.matches("^[A-Za-z0-9_-]+$", info.token)
  end)

  it("eagerly creates a missing absolute PNG target", function()
    local info, path = start_blank_session()

    local keys = {}
    for key in pairs(info) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    assert.are.same({ "browser_opened", "path", "url" }, keys)
    assert.are.equal(path, info.path)
    assert.is_true(info.browser_opened)
    assert.is_nil(info.warning)
    assert.are.equal(1, #fake_browser.calls)
    assert.is_table(uv.fs_stat(path))
    assert.are.same(empty_snapshot(), select(1, png.extract_snapshot(read_binary(path))))

    local status, headers, body = request_for(info, "GET", "/" .. session_token(info) .. "/", {}, "")
    assert.are.equal(200, status)
    assert.are.equal("text/html; charset=utf-8", header_value(headers, "content-type"))
    assert.is_not_nil(body:find("<!doctype html>", 1, true))
    assert.is_not_nil(body:find('rel="icon"', 1, true))
    assert.is_not_nil(body:find('href="data:,"', 1, true))
  end)

  it("creates a missing target before prompted creation succeeds", function()
    local path = vim.fn.tempname() .. ".png"
    os.remove(path)
    local info, err = session.start({ path = path, create = true })

    assert.is_nil(err)
    assert.is_not_nil(info)
    assert.are.same(empty_snapshot(), select(1, png.extract_snapshot(read_binary(path))))
    assert.is_true(session._test.get_target_baseline().exists)
    os.remove(path)
  end)

  it("rejects an existing target before prompted creation can replace it", function()
    local path = vim.fn.tempname() .. ".png"
    local original = read_binary("tests/fixtures/blank.png")
    local open_calls = 0
    write_binary(path, original)
    session._test.set_target_file_operations({
      create_open = function()
        open_calls = open_calls + 1
        return nil, "EACCES: staging should not start"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "TARGET_EXISTS",
      message = "A drawing with that name already exists. Choose another name.",
    }, err)
    assert.are.equal(0, open_calls)
    assert.are.equal(original, read_binary(path))
    os.remove(path)
  end)

  it("does not replace a target that appears after the creation preflight", function()
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_link = function(source)
        write_binary(path, read_binary(source))
        return nil, "EEXIST: target appeared"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.equal("TARGET_EXISTS", err.code)
    assert.are.equal("A drawing with that name already exists. Choose another name.", err.message)
    assert.are_not.equal(read_binary("tests/fixtures/blank.png"), read_binary(path))
    os.remove(path)
  end)

  it("rejects an existing Quickdraw target in prompted creation mode", function()
    local path = vim.fn.tempname() .. ".png"
    local original = embedded_png(vim.empty_dict())
    write_binary(path, original)

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.equal("TARGET_EXISTS", err.code)
    assert.are.equal(original, read_binary(path))
    os.remove(path)
  end)

  it("maps a real hard-link collision to TARGET_EXISTS without changing competing bytes", function()
    local path = vim.fn.tempname() .. ".png"
    local competing_bytes = "competing target bytes"
    local lstat_calls = 0
    session._test.set_target_file_operations({
      create_lstat = function(candidate)
        lstat_calls = lstat_calls + 1
        if lstat_calls == 3 then
          write_binary(path, competing_bytes)
        end
        return uv.fs_lstat(candidate)
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "TARGET_EXISTS",
      message = "A drawing with that name already exists. Choose another name.",
    }, err)
    assert.are.equal(competing_bytes, read_binary(path))
    assert.are.same({}, creation_temp_paths(path))
    os.remove(path)
  end)

  it("rejects a staging pathname replaced before the final link", function()
    local path = vim.fn.tempname() .. ".png"
    local replaced_path
    local moved_path
    local lstat_calls = 0
    session._test.set_target_file_operations({
      create_lstat = function(candidate)
        lstat_calls = lstat_calls + 1
        if lstat_calls == 3 then
          moved_path = candidate .. ".moved"
          assert.is_true(uv.fs_rename(candidate, moved_path))
          write_binary(candidate, "replacement staging bytes")
          replaced_path = candidate
        end
        return uv.fs_lstat(candidate)
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG changed before commit",
    }, err)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.equal("replacement staging bytes", read_binary(replaced_path))
    assert.is_table(uv.fs_lstat(moved_path))
    os.remove(replaced_path)
    os.remove(moved_path)
  end)

  it("does not remove an unowned staging path when exclusive open fails", function()
    local path = vim.fn.tempname() .. ".png"
    local staging_path
    session._test.set_target_file_operations({
      create_open = function(candidate)
        staging_path = candidate
        write_binary(candidate, "owned by another process")
        return nil, "EEXIST: staging path already exists"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be opened",
    }, err)
    assert.are.equal("owned by another process", read_binary(staging_path))
    assert.is_nil(uv.fs_lstat(path))
    os.remove(staging_path)
  end)

  it("cleans a failed staged write and permits a clean retry", function()
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_write = function()
        return nil, "EIO: injected creation failure"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be written",
    }, err)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
    session._test.set_target_file_operations()
    info, err = session.start({ path = path, create = true })
    assert.is_nil(err)
    assert.is_not_nil(info)
    assert.is_table(uv.fs_lstat(path))
    os.remove(path)
  end)

  it("rejects directories and symlinks as prompted creation targets", function()
    local directory = vim.fn.tempname() .. ".png"
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local info, err = session.start({ path = directory, create = true })
    assert.is_nil(info)
    assert.are.equal("TARGET_EXISTS", err.code)
    assert.are.equal(1, vim.fn.isdirectory(directory))
    vim.fn.delete(directory, "rf")

    if type(uv.fs_symlink) ~= "function" then
      return
    end
    local source = vim.fn.tempname() .. ".png"
    local link = vim.fn.tempname() .. ".png"
    write_binary(source, read_binary("tests/fixtures/blank.png"))
    if not uv.fs_symlink(source, link) then
      os.remove(source)
      return
    end
    info, err = session.start({ path = link, create = true })
    assert.is_nil(info)
    assert.are.equal("TARGET_EXISTS", err.code)
    assert.are.equal(source, uv.fs_readlink(link))
    vim.fn.delete(link)
    os.remove(source)
  end)

  it("preserves the active session when blank creation fails", function()
    local active = start({ ["GET /echo"] = { body = "old" } })
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_write = function()
        return nil, "EIO: injected creation failure"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.equal("CREATE_FAILED", err.code)
    assert.are.equal("old", select(3, request_for(active, "GET", "/" .. session_token(active) .. "/echo", {}, "")))
    assert.is_nil(uv.fs_lstat(path))
  end)

  it("reports an exact fstat failure and cleans the staged target", function()
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_fstat = function()
        return nil, "EIO: injected fstat failure"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be verified",
    }, err)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
  end)

  it("reports an exact post-close verification failure and cleans the staged target", function()
    local path = vim.fn.tempname() .. ".png"
    local lstat_calls = 0
    session._test.set_target_file_operations({
      create_lstat = function(target)
        lstat_calls = lstat_calls + 1
        if lstat_calls == 2 then
          return nil, "EIO: injected post-close verification failure"
        end
        return uv.fs_lstat(target)
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be verified after closing",
    }, err)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
    assert.are.equal(2, lstat_calls)
  end)

  it("closes the descriptor before reporting an exact close failure", function()
    local path = vim.fn.tempname() .. ".png"
    local close_calls = 0
    session._test.set_target_file_operations({
      create_close = function(fd)
        close_calls = close_calls + 1
        local close_ok, close_error = uv.fs_close(fd)
        assert.is_true(close_ok, close_error)
        return nil, "EIO: injected close failure"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be closed",
    }, err)
    assert.are.equal(1, close_calls)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
  end)

  it("reports an exact link failure and cleans the staged target", function()
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_link = function()
        return nil, "EIO: injected link failure"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be committed",
    }, err)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
  end)

  it("preserves the active session when the commit link fails", function()
    local active = start({ ["GET /echo"] = { body = "old" } })
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_link = function()
        return nil, "EIO: injected commit failure"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be committed",
    }, err)
    assert.are.equal("old", select(3, request_for(active, "GET", "/" .. session_token(active) .. "/echo", {}, "")))
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
  end)

  it("reports an unavailable hard-link implementation without a target", function()
    local path = vim.fn.tempname() .. ".png"
    session._test.set_target_file_operations({
      create_link = function()
        return nil, "ENOSYS: hard links unavailable"
      end,
    })

    local info, err = session.start({ path = path, create = true })

    assert.is_nil(info)
    assert.are.same({
      code = "CREATE_FAILED",
      message = "blank Quickdraw PNG could not be committed",
    }, err)
    assert.is_nil(uv.fs_lstat(path))
    assert.are.same({}, creation_temp_paths(path))
  end)

  it("launches the generated URL with the platform-specific argv", function()
    local platforms = {
      { name = "Darwin", argv = { "open" } },
      { name = "Linux", argv = { "xdg-open" } },
      { name = "Windows_NT", argv = { "rundll32.exe", "url.dll,FileProtocolHandler" } },
    }

    for _, expected in ipairs(platforms) do
      fake_browser.platform = expected.name
      fake_browser.calls = {}
      local target = vim.fn.tempname() .. "-not-in-argv.png"
      local info, err = session.start({ path = target })

      assert.is_nil(err)
      assert.is_true(info.browser_opened)
      assert.is_nil(info.warning)
      assert.are.equal(1, #fake_browser.calls)
      local call = fake_browser.calls[1]
      assert.are.same(vim.list_extend(vim.deepcopy(expected.argv), { info.url }), call.argv)
      assert.are.equal(true, call.options.detach)
      assert.is_nil(call.options.shell)
      assert.is_nil(table.concat(call.argv, "\\0"):find(target, 1, true))
      session.stop()
    end
  end)

  it("keeps the server usable when browser launch fails", function()
    local failures = {
      { result = nil },
      { result = 0 },
      { result = -1 },
      { throw = true },
      { platform = "Plan9", result = 1 },
    }

    for _, failure in ipairs(failures) do
      fake_browser.calls = {}
      fake_browser.platform = failure.platform or "Linux"
      fake_browser.result = failure.result
      fake_browser.throw = failure.throw
      local target = vim.fn.tempname() .. "-not-in-argv.png"
      local info, err = session.start({ path = target })

      assert.is_nil(err)
      assert.is_false(info.browser_opened)
      assert.are.same({ code = "BROWSER_OPEN_FAILED", message = "default browser could not be opened" }, info.warning)
      assert.are.equal(200, select(1, request_for(info, "GET", "/" .. session_token(info) .. "/api/snapshot", {}, "")))
      assert.is_nil(
        table.concat(fake_browser.calls[1] and fake_browser.calls[1].argv or {}, "\\0"):find(target, 1, true)
      )
      session.stop()
    end
  end)

  it("shares singleton state and lifecycle callbacks across module reloads", function()
    local first = start_blank_session()
    local first_host, first_port = endpoint(first)
    local first_token = session_token(first)
    local old_client = uv.new_tcp()
    local connected = false
    local eof = false
    local connect_error
    old_client:connect(first_host, first_port, function(err)
      connect_error = err
      if err then
        return
      end
      connected = true
      old_client:read_start(function(read_error, data)
        eof = read_error ~= nil or data == nil
      end)
    end)
    wait_for(function()
      return connected or connect_error ~= nil
    end)
    assert.is_true(connected)
    assert.is_nil(connect_error)

    local original_loaded = package.loaded["quickdraw.session"]
    package.loaded["quickdraw.session"] = nil
    local ok, failure = xpcall(function()
      local reloaded = require("quickdraw.session")
      reloaded._test.set_browser_launcher({
        platform = "Linux",
        spawn = function()
          return 1
        end,
      })
      local second, err = reloaded.start({ path = vim.fn.tempname() .. ".png" })
      assert.is_nil(err)
      assert.is_true(second.browser_opened)
      assert.are_not.equal(first.url, second.url)
      assert_connection_rejected(first)
      wait_for(function()
        return eof
      end)
      assert.is_true(eof)
      assert.are.equal(
        200,
        select(1, request_for(second, "GET", "/" .. session_token(second) .. "/api/snapshot", {}, ""))
      )
      assert.are.equal(1, #vim.api.nvim_get_autocmds({ event = "VimLeavePre", group = "QuickdrawSession" }))
      local stopped, stop_error = reloaded.stop()
      assert.is_true(stopped)
      assert.is_nil(stop_error)
      assert_connection_rejected(second)
      assert.are_not.equal(first_token, session_token(second))
    end, debug.traceback)
    package.loaded["quickdraw.session"] = original_loaded
    if not old_client:is_closing() then
      old_client:close()
    end
    assert.is_true(ok, failure)
  end)

  it("preserves an old session when lifecycle registration fails and retries", function()
    local old = start({ ["GET /echo"] = { body = "old" } })
    local group_calls = 0
    session._test.set_lifecycle_api({
      create_augroup = function()
        group_calls = group_calls + 1
        error("injected augroup failure")
      end,
    })

    local info, err = session.start({ path = vim.fn.tempname() .. ".png" })

    assert.is_nil(info)
    assert.are.same({ code = "SERVER_FAILED", message = "session lifecycle unavailable" }, err)
    assert.are.equal(1, group_calls)
    assert.are.equal("old", select(3, request_for(old, "GET", "/" .. session_token(old) .. "/echo", {}, "")))

    session._test.set_lifecycle_api()
    local replacement, replacement_error = session.start({ path = vim.fn.tempname() .. ".png" })
    assert.is_nil(replacement_error)
    assert.is_not_nil(replacement)
    assert.are.equal(1, #vim.api.nvim_get_autocmds({ event = "VimLeavePre", group = "QuickdrawSession" }))
  end)

  it("clears a partial lifecycle registration before retrying", function()
    local old = start({ ["GET /echo"] = { body = "old" } })
    local autocmd_calls = 0
    session._test.set_lifecycle_api({
      create_augroup = function(name, opts)
        return vim.api.nvim_create_augroup(name, opts)
      end,
      create_autocmd = function()
        autocmd_calls = autocmd_calls + 1
        error("injected autocmd failure")
      end,
    })

    local info, err = session.start({ path = vim.fn.tempname() .. ".png" })

    assert.is_nil(info)
    assert.are.same({ code = "SERVER_FAILED", message = "session lifecycle unavailable" }, err)
    assert.are.equal(1, autocmd_calls)
    assert.are.equal("old", select(3, request_for(old, "GET", "/" .. session_token(old) .. "/echo", {}, "")))

    session._test.set_lifecycle_api()
    local replacement, replacement_error = session.start({ path = vim.fn.tempname() .. ".png" })
    assert.is_nil(replacement_error)
    assert.is_not_nil(replacement)
    assert.are.equal(1, #vim.api.nvim_get_autocmds({ event = "VimLeavePre", group = "QuickdrawSession" }))
  end)

  it("reports cleanup failures and remains idempotent", function()
    local fake_session = {
      stopped = false,
      listener = {
        is_closing = function()
          return false
        end,
        stop = function()
          error("stop failed")
        end,
        close = function()
          error("close failed")
        end,
      },
      clients = {},
      target_baseline = {},
      current_snapshot = {},
      target_path = "/private/target.png",
      token = "secret",
      port = 1234,
      url = "http://127.0.0.1:1234/secret/",
    }
    local fake_state = {
      closed = false,
      session = fake_session,
      timer = {
        stop = function()
          error("timer stop failed")
        end,
        close = function()
          error("timer close failed")
        end,
        is_closing = function()
          return false
        end,
      },
      client = {
        is_closing = function()
          return false
        end,
        read_stop = function()
          error("read stop failed")
        end,
        close = function()
          error("client close failed")
        end,
      },
    }
    fake_session.clients[fake_state] = true
    session._test.set_active_session(fake_session)

    local ok, err = session.stop()

    assert.is_nil(ok)
    assert.are.same({ code = "SERVER_FAILED", message = "session cleanup failed" }, err)
    assert.is_true(fake_session.stopped)
    assert.is_nil(fake_session.listener)
    assert.is_nil(fake_session.token)
    assert.is_nil(session._test.get_active_token())
    local second_ok, second_error = session.stop()
    assert.is_true(second_ok)
    assert.is_nil(second_error)
  end)

  it("replaces the singleton and closes old clients", function()
    local first = start_blank_session()
    local host, port = endpoint(first)
    local client = uv.new_tcp()
    local connected = false
    local eof = false
    local connect_error
    client:connect(host, port, function(err)
      connect_error = err
      if err then
        return
      end
      connected = true
      client:read_start(function(read_error, data)
        eof = read_error ~= nil or data == nil
      end)
    end)
    wait_for(function()
      return connected or connect_error ~= nil
    end)
    assert.is_true(connected)
    assert.is_nil(connect_error)

    local second = start_blank_session()
    assert.is_true(second.browser_opened)
    wait_for(function()
      return eof
    end)
    assert.is_true(eof)
    if not client:is_closing() then
      client:close()
    end
    assert.are.equal(
      200,
      select(1, request_for(second, "GET", "/" .. session_token(second) .. "/api/snapshot", {}, ""))
    )
  end)

  it("registers one exit autocmd and clears private state", function()
    local info = start_blank_session()
    local first_count = #vim.api.nvim_get_autocmds({ event = "VimLeavePre", group = "QuickdrawSession" })
    local baseline = session._test.get_target_baseline()
    assert.is_table(baseline)
    assert.is_table(session._test.get_current_snapshot())

    local second = start_blank_session()
    local second_count = #vim.api.nvim_get_autocmds({ event = "VimLeavePre", group = "QuickdrawSession" })
    assert.is_true(first_count > 0)
    assert.are.equal(first_count, second_count)
    assert.are_not.equal(info.url, second.url)

    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    assert_connection_rejected(second)
    assert.is_nil(session._test.get_target_baseline())
    assert.is_nil(session._test.get_current_snapshot())
    assert.is_nil(session._test.get_active_token())
    assert.is_true(session.stop())
    assert.is_true(session.stop())

    local reopened = start_blank_session()
    assert.is_true(reopened.browser_opened)
    assert.are.equal(
      200,
      select(1, request_for(reopened, "GET", "/" .. session_token(reopened) .. "/api/snapshot", {}, ""))
    )
  end)

  it("preflights and serves an embedded snapshot", function()
    local expected = {
      document = {
        store = {
          shape = {
            id = "shape",
            typeName = "shape",
            type = "geo",
            x = 10,
            y = 20,
            rot = 0,
            z = 1,
            props = {
              geo = "rectangle",
              w = 320,
              h = 180,
              color = "blue",
              size = "m",
              dash = "draw",
              fill = "semi",
              font = "draw",
            },
          },
        },
      },
    }
    local info = start_existing_session(expected)

    assert.are.same(expected, get_snapshot(info))
  end)

  it("preserves an embedded empty snapshot as a JSON object", function()
    local info = start_existing_session(vim.empty_dict())
    local snapshot = get_snapshot(info)

    assert.are.same({}, snapshot)
    assert.is_false(is_list(snapshot))
  end)

  it("retains exact target bytes privately and clears the baseline on stop", function()
    local info, path = start_existing_session(vim.empty_dict())
    local baseline = session._test.get_target_baseline()
    local bytes = read_binary(path)

    assert.is_true(baseline.exists)
    assert.are.equal(bytes, baseline.bytes)
    assert.are.equal(#bytes, baseline.size)
    assert.is_nil(info.target_baseline)

    session.stop()
    assert.is_nil(session._test.get_target_baseline())
    os.remove(path)

    local missing_info, missing_path = start_blank_session()
    local missing_baseline = session._test.get_target_baseline()
    assert.is_true(missing_baseline.exists)
    assert.is_nil(missing_info.target_baseline)
    assert.is_table(uv.fs_stat(missing_path))
    session.stop()
    assert.is_nil(session._test.get_target_baseline())
    os.remove(missing_path)
  end)

  it("saves one multipart request and updates the target baseline", function()
    local info, path = start_blank_session()
    local expected = {
      document = {
        store = {
          saved = {
            id = "saved",
            typeName = "shape",
            type = "geo",
            x = 12,
            y = 24,
            rot = 0,
            z = 1,
            props = {
              geo = "rectangle",
              w = 120,
              h = 80,
              color = "blue",
              size = "m",
              dash = "draw",
              fill = "semi",
              font = "draw",
            },
          },
        },
      },
    }
    local boundary = "Task5Boundary"
    local body = multipart_body(boundary, {
      {
        disposition = 'form-data; name="snapshot"; filename="snapshot.json"',
        content_type = "application/json",
        body = vim.json.encode(expected),
      },
      {
        disposition = 'form-data; name="png"; filename="drawing.png"',
        content_type = "image/png",
        body = read_binary("tests/fixtures/blank.png"),
      },
    })

    local status, _, response_body = save_request(info, body, "multipart/form-data; boundary=" .. boundary)
    assert.are.equal(200, status)
    assert.are.same({ ok = true }, vim.json.decode(response_body))
    assert.are.same(expected, select(1, png.extract_snapshot(read_binary(path))))
    assert.are.same(expected, get_snapshot(info))
    assert.are.equal(read_binary(path), session._test.get_target_baseline().bytes)

    local second = vim.deepcopy(expected)
    second.document.store.saved.x = 99
    local second_body = multipart_body(boundary, {
      {
        disposition = 'form-data; name="snapshot"; filename="snapshot.json"',
        content_type = "application/json",
        body = vim.json.encode(second),
      },
      {
        disposition = 'form-data; name="png"; filename="drawing.png"',
        content_type = "image/png",
        body = read_binary("tests/fixtures/blank.png"),
      },
    })
    status = select(1, save_request(info, second_body, "multipart/form-data; boundary=" .. boundary))
    assert.are.equal(200, status)
    assert.are.same(second, select(1, png.extract_snapshot(read_binary(path))))
    assert.are.same(second, get_snapshot(info))
    os.remove(path)
  end)

  it("rejects malformed multipart inputs without changing the target", function()
    local expected = embedded_png(vim.empty_dict())
    local cases = {
      {
        name = "missing snapshot",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "missing png",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
          })
        end,
      },
      {
        name = "duplicate snapshot",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="snapshot"; filename="other.json"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "duplicate png",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="a.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
            {
              disposition = 'form-data; name="png"; filename="b.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "unknown field",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="extra"',
              content_type = "text/plain",
              body = "no",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "path-like field name",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="../snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "path-like filename",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="../drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "invalid json",
        code = "INVALID_SNAPSHOT",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "[]",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "invalid png",
        code = "INVALID_CHUNK",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"):sub(1, -2),
            },
          })
        end,
      },
      {
        name = "wrong snapshot media type",
        status = 415,
        code = "UNSUPPORTED_MEDIA_TYPE",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "text/plain",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "wrong png media type",
        status = 415,
        code = "UNSUPPORTED_MEDIA_TYPE",
        body = function(boundary)
          return multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "application/octet-stream",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
        end,
      },
      {
        name = "missing snapshot media type",
        status = 415,
        code = "UNSUPPORTED_MEDIA_TYPE",
        body = function(boundary)
          return table.concat({
            "--",
            boundary,
            '\r\nContent-Disposition: form-data; name="snapshot"\r\n\r\n{}\r\n--',
            boundary,
            '\r\nContent-Disposition: form-data; name="png"; filename="drawing.png"\r\n',
            "Content-Type: image/png\r\n\r\n",
            read_binary("tests/fixtures/blank.png"),
            "\r\n--",
            boundary,
            "--\r\n",
          })
        end,
      },
      {
        name = "truncated delimiters",
        body = function(boundary)
          return "--" .. boundary .. "\r\n"
        end,
      },
      {
        name = "malformed closing delimiter",
        body = function(boundary)
          local body = multipart_body(boundary, {
            {
              disposition = 'form-data; name="snapshot"',
              content_type = "application/json",
              body = "{}",
            },
            {
              disposition = 'form-data; name="png"; filename="drawing.png"',
              content_type = "image/png",
              body = read_binary("tests/fixtures/blank.png"),
            },
          })
          return body:sub(1, #body - 4) .. "-\r\n"
        end,
      },
    }
    for _, case in ipairs(cases) do
      local info, path = start_existing_session(vim.empty_dict())
      local original = read_binary(path)
      local boundary = "MalformedBoundary"
      local status, _, response = save_request(info, case.body(boundary), "multipart/form-data; boundary=" .. boundary)
      assert.are.equal(case.status or 400, status, case.name)
      assert.are.equal(case.code or "INVALID_MULTIPART", vim.json.decode(response).error.code, case.name)
      assert.are.equal(original, read_binary(path), case.name)
      os.remove(path)
    end
  end)

  it("tolerates boundary-like bytes inside a valid PNG part", function()
    local info, path = start_blank_session()
    local boundary = "BoundaryLike"
    local png_bytes =
      add_text_chunk(read_binary("tests/fixtures/blank.png"), "prefix\r\n--" .. boundary .. "X\r\nsuffix")
    local expected = { document = { store = {} } }
    local body = multipart_body(boundary, {
      {
        disposition = 'form-data; name="snapshot"',
        content_type = "application/json",
        body = vim.json.encode(expected),
      },
      {
        disposition = 'form-data; name="png"; filename="drawing.png"',
        content_type = "image/png",
        body = png_bytes,
      },
    })
    local status, _, response = save_request(info, body, "multipart/form-data; boundary=" .. boundary)
    assert.are.equal(200, status, response)
    assert.are.same(expected, select(1, png.extract_snapshot(read_binary(path))))
    os.remove(path)
  end)

  it("accepts a valid multipart body larger than sixteen MiB", function()
    local info, path = start_blank_session()
    local expected = { payload = string.rep("x", 16 * 1024 * 1024) }
    local boundary = "LargeBodyBoundary"
    local body = multipart_body(boundary, {
      {
        disposition = 'form-data; name="snapshot"',
        content_type = "application/json",
        body = vim.json.encode(expected),
      },
      {
        disposition = 'form-data; name="png"; filename="drawing.png"',
        content_type = "image/png",
        body = read_binary("tests/fixtures/blank.png"),
      },
    })
    assert.is_true(#body > 16 * 1024 * 1024)
    local status = select(1, save_request(info, body, "multipart/form-data; boundary=" .. boundary))
    assert.are.equal(200, status)
    assert.are.same(expected, select(1, png.extract_snapshot(read_binary(path))))
    os.remove(path)
  end)

  it("returns TARGET_CHANGED for every target replacement race", function()
    local replacement = embedded_png({ replacement = true })
    local save_body = function()
      local boundary = "TargetRaceBoundary"
      return multipart_body(boundary, {
        {
          disposition = 'form-data; name="snapshot"',
          content_type = "application/json",
          body = "{}",
        },
        {
          disposition = 'form-data; name="png"; filename="drawing.png"',
          content_type = "image/png",
          body = read_binary("tests/fixtures/blank.png"),
        },
      }),
        "multipart/form-data; boundary=" .. boundary
    end

    local info, path = start_blank_session()
    write_binary(path, replacement)
    local body, content_type = save_body()
    local status, _, response = save_request(info, body, content_type)
    assert.are.equal(409, status)
    assert.are.equal("TARGET_CHANGED", vim.json.decode(response).error.code)
    assert.are.equal(replacement, read_binary(path))
    os.remove(path)

    info, path = start_existing_session(vim.empty_dict())
    local original = read_binary(path)
    os.remove(path)
    body, content_type = save_body()
    status, _, response = save_request(info, body, content_type)
    assert.are.equal(409, status)
    assert.are.equal("TARGET_CHANGED", vim.json.decode(response).error.code)
    assert.is_nil(uv.fs_stat(path))

    info, path = start_existing_session(vim.empty_dict())
    original = read_binary(path)
    local other = vim.fn.tempname() .. ".png"
    write_binary(other, replacement)
    assert.is_true(uv.fs_rename(other, path))
    body, content_type = save_body()
    status, _, response = save_request(info, body, content_type)
    assert.are.equal(409, status)
    assert.are.equal("TARGET_CHANGED", vim.json.decode(response).error.code)
    assert.are.equal(replacement, read_binary(path))
    os.remove(path)

    info, path = start_existing_session(vim.empty_dict())
    original = read_binary(path)
    write_binary(path, replacement)
    body, content_type = save_body()
    status, _, response = save_request(info, body, content_type)
    assert.are.equal(409, status)
    assert.are.equal("TARGET_CHANGED", vim.json.decode(response).error.code)
    assert.are.equal(replacement, read_binary(path))
    assert.are_not.equal(original, replacement)
    os.remove(path)

    if type(uv.fs_symlink) == "function" then
      info, path = start_existing_session(vim.empty_dict())
      local link_target = vim.fn.tempname() .. ".png"
      write_binary(link_target, replacement)
      os.remove(path)
      if uv.fs_symlink(link_target, path) then
        body, content_type = save_body()
        status, _, response = save_request(info, body, content_type)
        assert.are.equal(409, status)
        assert.are.equal("TARGET_CHANGED", vim.json.decode(response).error.code)
      end
      os.remove(path)
      os.remove(link_target)
    end
  end)

  it("rejects a target changed during temp work before rename", function()
    local info, path = start_existing_session(vim.empty_dict())
    local replacement = embedded_png({ changed_during_save = true })
    local changed = false
    session._test.set_target_file_operations({
      temp_write = function(fd, data, offset)
        if not changed then
          changed = true
          write_binary(path, replacement)
        end
        return uv.fs_write(fd, data, offset)
      end,
    })
    local boundary = "DuringSaveBoundary"
    local body = multipart_body(boundary, {
      {
        disposition = 'form-data; name="snapshot"',
        content_type = "application/json",
        body = "{}",
      },
      {
        disposition = 'form-data; name="png"; filename="drawing.png"',
        content_type = "image/png",
        body = read_binary("tests/fixtures/blank.png"),
      },
    })

    local status, _, response = save_request(info, body, "multipart/form-data; boundary=" .. boundary)
    assert.are.equal(409, status)
    assert.are.equal("TARGET_CHANGED", vim.json.decode(response).error.code)
    assert.are.equal(replacement, read_binary(path))
    os.remove(path)
  end)

  it("uses an exclusive temp file, handles partial writes, and cleans up failures", function()
    local failure_modes = {
      "open",
      "write",
      "fstat",
      "fstat-size",
      "lstat",
      "lstat-size",
      "lstat-identity",
      "close",
      "rename",
    }
    for _, mode in ipairs(failure_modes) do
      local info, path = start_existing_session(vim.empty_dict())
      local original = read_binary(path)
      local temp_path
      local operations = {
        temp_open = function(candidate, flags, permissions)
          temp_path = candidate
          assert.are.equal("wx", flags)
          assert.are.equal(384, permissions)
          assert.is_nil(candidate:find(session_token(info), 1, true))
          if mode == "open" then
            return nil, "EACCES"
          end
          return uv.fs_open(candidate, flags, permissions)
        end,
      }
      if mode == "write" then
        operations.temp_write = function()
          return nil, "EIO"
        end
      elseif mode == "fstat" then
        operations.temp_fstat = function()
          return nil, "EIO"
        end
      elseif mode == "fstat-size" then
        operations.temp_fstat = function(fd)
          local stat, stat_error = uv.fs_fstat(fd)
          if not stat then
            return nil, stat_error
          end
          stat.size = stat.size - 1
          return stat
        end
      elseif mode == "lstat" then
        operations.temp_lstat = function()
          return nil, "EIO"
        end
      elseif mode == "lstat-size" then
        operations.temp_lstat = function(candidate)
          local stat, stat_error = uv.fs_lstat(candidate)
          if not stat then
            return nil, stat_error
          end
          stat.size = stat.size - 1
          return stat
        end
      elseif mode == "lstat-identity" then
        operations.temp_lstat = function(candidate)
          local stat, stat_error = uv.fs_lstat(candidate)
          if not stat then
            return nil, stat_error
          end
          stat.ino = stat.ino + 1
          return stat
        end
      elseif mode == "close" then
        operations.temp_close = function(fd)
          uv.fs_close(fd)
          return nil, "EIO"
        end
      elseif mode == "rename" then
        operations.temp_rename = function()
          return nil, "EIO"
        end
      end
      session._test.set_target_file_operations(operations)
      local boundary = "TempFailureBoundary"
      local body = multipart_body(boundary, {
        {
          disposition = 'form-data; name="snapshot"',
          content_type = "application/json",
          body = "{}",
        },
        {
          disposition = 'form-data; name="png"; filename="drawing.png"',
          content_type = "image/png",
          body = read_binary("tests/fixtures/blank.png"),
        },
      })
      local status, _, response = save_request(info, body, "multipart/form-data; boundary=" .. boundary)
      assert.are.equal(500, status, mode)
      assert.are.equal("SAVE_FAILED", vim.json.decode(response).error.code, mode)
      assert.are.equal(original, read_binary(path), mode)
      if temp_path then
        assert.is_nil(uv.fs_stat(temp_path), mode)
      end
      os.remove(path)
    end

    local info, path = start_existing_session(vim.empty_dict())
    local original = read_binary(path)
    local write_calls = 0
    local expected = { changed = true }
    session._test.set_target_file_operations({
      temp_write = function(fd, data, offset)
        write_calls = write_calls + 1
        local part = data:sub(1, math.min(3, #data))
        return uv.fs_write(fd, part, offset)
      end,
    })
    local boundary = "PartialWriteBoundary"
    local body = multipart_body(boundary, {
      {
        disposition = 'form-data; name="snapshot"',
        content_type = "application/json",
        body = vim.json.encode(expected),
      },
      {
        disposition = 'form-data; name="png"; filename="drawing.png"',
        content_type = "image/png",
        body = read_binary("tests/fixtures/blank.png"),
      },
    })
    local status, _, response = save_request(info, body, "multipart/form-data; boundary=" .. boundary)
    assert.are.equal(200, status, response)
    assert.is_true(write_calls > 1)
    local saved = read_binary(path)
    local expected_png = embedded_png(expected)
    assert.are.equal(expected_png, saved)
    assert.are.same(expected, select(1, png.extract_snapshot(saved)))
    assert.are_not.equal(original, saved)
    os.remove(path)
  end)

  it("rejects an invalid save content type and boundary", function()
    local info, path = start_blank_session()
    local body = "not multipart"
    local status, _, response = save_request(info, body, "application/octet-stream")
    assert.are.equal(415, status)
    assert.are.equal("UNSUPPORTED_MEDIA_TYPE", vim.json.decode(response).error.code)
    assert.is_table(uv.fs_stat(path))
    local original = read_binary(path)

    local boundary = "BadBoundary"
    body = multipart_body(boundary, {})
    status, _, response = save_request(info, body, "multipart/form-data")
    assert.are.equal(400, status)
    assert.are.equal("INVALID_MULTIPART", vim.json.decode(response).error.code)
    assert.are.equal(original, read_binary(path))
    os.remove(path)
  end)

  it("rejects an existing ordinary PNG before consuming entropy", function()
    local path = vim.fn.tempname() .. ".png"
    local original = read_binary("tests/fixtures/blank.png")
    write_binary(path, original)
    local random_calls = 0
    session._test.set_random_source(function()
      random_calls = random_calls + 1
      return string.rep("x", 32)
    end)

    local info, err = session.start({ path = path })

    assert.is_nil(info)
    assert.are.equal("NOT_QUICKDRAW", err.code)
    assert.are.equal(0, random_calls)
    assert.are.equal(original, read_binary(path))
    os.remove(path)
  end)

  it("returns the existing PNG validation error before binding", function()
    local path = vim.fn.tempname() .. ".png"
    local corrupt = read_binary("tests/fixtures/blank.png"):sub(1, -2)
    write_binary(path, corrupt)
    local _, expected_error = png.extract_snapshot(corrupt)
    local random_calls = 0
    session._test.set_random_source(function()
      random_calls = random_calls + 1
      return string.rep("x", 32)
    end)

    local info, err = session.start({ path = path })

    assert.is_nil(info)
    assert.are.equal("INVALID_CHUNK", err.code)
    assert.are.same(expected_error, err)
    assert.are.equal(0, random_calls)
    assert.are.equal(corrupt, read_binary(path))
    os.remove(path)
  end)

  it("returns READ_FAILED for non-regular targets", function()
    local directory = vim.fn.tempname() .. ".png"
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    local info, err = session.start({ path = directory })
    assert.is_nil(info)
    assert.are.equal("READ_FAILED", err.code)
    vim.fn.delete(directory, "rf")
  end)

  it("rejects a symlink target when the platform permits creating one", function()
    if type(uv.fs_symlink) ~= "function" then
      return
    end

    local target = vim.fn.fnamemodify("tests/fixtures/blank.png", ":p")
    local link = vim.fn.tempname() .. ".png"
    local created = uv.fs_symlink(target, link)
    if not created then
      return
    end

    local info, err = session.start({ path = link })

    assert.is_nil(info)
    assert.are.equal("READ_FAILED", err.code)
    vim.fn.delete(link)
  end)

  it("maps injected target open and read failures to READ_FAILED", function()
    local path = vim.fn.tempname() .. ".png"
    write_binary(path, embedded_png(vim.empty_dict()))

    session._test.set_target_file_operations({
      open = function()
        return nil, "EACCES: injected open failure"
      end,
    })
    local info, err = session.start({ path = path })
    assert.is_nil(info)
    assert.are.equal("READ_FAILED", err.code)

    local close_calls = 0
    session._test.set_target_file_operations({
      read = function()
        return nil, "EIO: injected read failure"
      end,
      close = function(fd)
        close_calls = close_calls + 1
        return uv.fs_close(fd)
      end,
    })
    info, err = session.start({ path = path })
    assert.is_nil(info)
    assert.are.equal("READ_FAILED", err.code)
    assert.are.equal(1, close_calls)
    os.remove(path)
  end)

  it("rejects a target when its descriptor identity changes", function()
    local path = vim.fn.tempname() .. ".png"
    write_binary(path, embedded_png(vim.empty_dict()))
    local close_calls = 0

    session._test.set_target_file_operations({
      fstat = function(fd)
        local stat, stat_error = uv.fs_fstat(fd)
        if not stat then
          return nil, stat_error
        end
        stat.ino = stat.ino + 1
        return stat
      end,
      close = function(fd)
        close_calls = close_calls + 1
        return uv.fs_close(fd)
      end,
    })
    local info, err = session.start({ path = path })

    assert.is_nil(info)
    assert.are.equal("READ_FAILED", err.code)
    assert.are.equal(1, close_calls)
    os.remove(path)
  end)

  it("rejects relative and non-PNG targets before binding", function()
    local info, err = session.start({ path = "drawing.png" })
    assert.is_nil(info)
    assert.are.equal("INVALID_PATH", err.code)

    local path = vim.fn.tempname()
    info, err = session.start({ path = path })
    assert.is_nil(info)
    assert.are.equal("INVALID_PATH", err.code)
    assert.is_nil(uv.fs_stat(path))
  end)

  it("keeps the active session for every preflight failure", function()
    local random_calls = 0
    session._test.set_random_source(function()
      random_calls = random_calls + 1
      return string.rep("q", 32)
    end)
    local active_info = start_blank_session()
    assert.are.equal(1, random_calls)

    local cases = {
      {
        name = "invalid path",
        path = "drawing.png",
        code = "INVALID_PATH",
      },
      {
        name = "ordinary PNG",
        path = vim.fn.tempname() .. ".png",
        code = "NOT_QUICKDRAW",
        setup = function(path)
          write_binary(path, read_binary("tests/fixtures/blank.png"))
        end,
      },
      {
        name = "corrupt PNG",
        path = vim.fn.tempname() .. ".png",
        code = "INVALID_CHUNK",
        setup = function(path)
          write_binary(path, read_binary("tests/fixtures/blank.png"):sub(1, -2))
        end,
      },
      {
        name = "target read",
        path = vim.fn.tempname() .. ".png",
        code = "READ_FAILED",
        setup = function(path)
          write_binary(path, embedded_png(vim.empty_dict()))
          session._test.set_target_file_operations({
            read = function()
              return nil, "EIO: injected read failure"
            end,
          })
        end,
      },
      {
        name = "editor asset",
        path = vim.fn.tempname() .. ".png",
        code = "SERVER_FAILED",
        setup = function()
          local root = vim.fn.tempname()
          local shadow_dir = root .. "/web/quickdraw"
          vim.fn.mkdir(shadow_dir, "p")
          vim.fn.writefile({ "<!doctype html><title>shadow</title>" }, shadow_dir .. "/index.html")
          local original_runtimepath = vim.o.runtimepath
          vim.opt.rtp:prepend(root)
          return function()
            vim.o.runtimepath = original_runtimepath
            vim.fn.delete(root, "rf")
          end
        end,
      },
    }

    for _, case in ipairs(cases) do
      session._test.set_target_file_operations({})
      local cleanup = case.setup and case.setup(case.path)
      local replacement_info, err = session.start({ path = case.path })
      if cleanup then
        cleanup()
      end

      assert.is_nil(replacement_info, case.name)
      assert.are.equal(case.code, err.code, case.name)
      assert.are.equal(1, random_calls, case.name)
      assert.are.same(empty_snapshot(), get_snapshot(active_info), case.name)
      if case.path:sub(1, 1) == "/" then
        os.remove(case.path)
      end
    end
  end)

  it("fails cleanly instead of mixing a partial shadow asset root", function()
    local root = vim.fn.tempname()
    local shadow_dir = root .. "/web/quickdraw"
    vim.fn.mkdir(shadow_dir, "p")
    vim.fn.writefile({ "<!doctype html><title>shadow</title>" }, shadow_dir .. "/index.html")

    local original_runtimepath = vim.o.runtimepath
    vim.opt.rtp:prepend(root)
    local info, err = session.start({ path = vim.fn.tempname() .. ".png" })
    vim.o.runtimepath = original_runtimepath
    vim.fn.delete(root, "rf")

    assert.is_nil(info)
    assert.are.equal("SERVER_FAILED", err.code)
  end)

  it("serves the exact native editor assets with same-origin content", function()
    local info = start_blank_session()
    local assets = {
      { path = "/", content_type = "text/html; charset=utf-8", marker = "<!doctype html>" },
      { path = "/app.js", content_type = "text/javascript; charset=utf-8", marker = "createQuickdraw" },
      { path = "/save_status.js", content_type = "text/javascript; charset=utf-8", marker = "createSaveStatus" },
      { path = "/app.css", content_type = "text/css; charset=utf-8", marker = "#board" },
      { path = "/blank.png", content_type = "image/png", body = read_binary("web/quickdraw/blank.png") },
      {
        path = "/vendor/@quickdrawjs/core/src/index.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "createQuickdraw",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/editor.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export class Editor",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/freehand.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export function strokeOutline",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/geometry.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export const",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/palette.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export const",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/shapes.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export function",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/store.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export class Store",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/ui.js",
        content_type = "text/javascript; charset=utf-8",
        marker = "export function buildUI",
      },
      {
        path = "/vendor/@quickdrawjs/core/src/quickdraw.css",
        content_type = "text/css; charset=utf-8",
        marker = ".qd-root",
      },
    }

    for _, asset in ipairs(assets) do
      local status, headers, body = request_for(info, "GET", "/" .. session_token(info) .. asset.path, {}, "")
      assert.are.equal(200, status, asset.path)
      assert.are.equal(asset.content_type, header_value(headers, "content-type"), asset.path)
      if asset.body then
        assert.are.equal(asset.body, body, asset.path)
      else
        assert.is_not_nil(body:find(asset.marker, 1, true), asset.path)
      end
      if asset.path == "/app.css" then
        assert.is_not_nil(body:find("#board:focus-visible", 1, true))
        assert.is_not_nil(body:find("#save-status", 1, true))
      end
    end
  end)

  it("returns the canonical blank snapshot and restrictive headers", function()
    local info = start_blank_session()
    local status, headers, body = request_for(info, "GET", "/" .. session_token(info) .. "/api/snapshot", {}, "")

    assert.are.equal(200, status)
    assert.are.equal("application/json; charset=utf-8", header_value(headers, "content-type"))
    assert.are.same(empty_snapshot(), vim.json.decode(body))
    assert.is_false(is_list(vim.json.decode(body).document))
    assert.is_false(is_list(vim.json.decode(body).document.store))
    assert.matches("default%-src 'self'", header_value(headers, "content-security-policy"))
    assert.matches("script%-src 'self'", header_value(headers, "content-security-policy"))
    assert.matches("connect%-src 'self'", header_value(headers, "content-security-policy"))
    assert.matches("style%-src%-attr 'unsafe%-inline'", header_value(headers, "content-security-policy"))
    assert.matches("img%-src 'self' data: blob:", header_value(headers, "content-security-policy"))
    assert.matches("object%-src 'none'", header_value(headers, "content-security-policy"))
    assert.are.equal("nosniff", header_value(headers, "x-content-type-options"))
    assert.are.equal("no-referrer", header_value(headers, "referrer-policy"))
    assert.are.equal("no-store", header_value(headers, "cache-control"))
  end)

  it("returns a sanitized 404 for unknown assets without exposing the target path", function()
    local info, path = start_blank_session()
    local requested_path = "/private/should-not-be-served.png"
    local status, _, body = request_for(info, "GET", "/" .. session_token(info) .. requested_path, {}, "")

    assert.are.equal(404, status)
    assert.are.same({ error = { code = "NOT_FOUND", message = "not found" } }, vim.json.decode(body))
    assert.is_nil(body:find(path, 1, true))
    assert.is_table(uv.fs_stat(path))
    os.remove(path)
  end)

  it("uses only same-origin browser code and textContent for errors", function()
    local info = start_blank_session()
    local status, _, index = request_for(info, "GET", "/" .. session_token(info) .. "/", {}, "")
    assert.are.equal(200, status)
    assert.is_not_nil(index:find("./app.js", 1, true))
    assert.is_not_nil(index:find("./app.css", 1, true))
    assert.is_nil(index:find("http://", 1, true))

    status, _, body = request_for(info, "GET", "/" .. session_token(info) .. "/app.js", {}, "")
    assert.are.equal(200, status)
    assert.is_not_nil(body:find('from "./vendor/@quickdrawjs/core/src/index.js"', 1, true))
    assert.is_not_nil(body:find('from "./save_status.js"', 1, true))
    assert.is_not_nil(body:find('fetch("./api/snapshot"', 1, true))
    assert.is_not_nil(body:find('fetch("./api/save"', 1, true))
    assert.is_not_nil(body:find('fetch("./blank.png"', 1, true))
    assert.is_not_nil(body:find('method: "POST"', 1, true))
    assert.is_not_nil(body:find("new FormData()", 1, true))
    assert.is_not_nil(body:find("getSnapshot()", 1, true))
    assert.is_not_nil(body:find('form.append("snapshot"', 1, true))
    assert.is_not_nil(body:find('type: "application/json"', 1, true))
    assert.is_not_nil(body:find('form.append("png", png, "drawing.png")', 1, true))
    assert.is_not_nil(body:find("clearError()", 1, true))
    assert.is_not_nil(body:find('loadSnapshot(snapshot, "remote")', 1, true))
    assert.is_not_nil(body:find('markChanged("user")', 1, true))
    assert.is_not_nil(body:find("fitContent()", 1, true))
    assert.is_not_nil(body:find("textContent", 1, true))
    assert.is_nil(body:find("innerHTML", 1, true))
    assert.is_nil(body:find("https://", 1, true))
  end)

  it("fails closed when the OS random source cannot provide a token", function()
    session._test.set_random_source(function()
      return nil, "entropy unavailable"
    end)

    local info, err = session._test.start({ routes = {} })

    assert.is_nil(info)
    assert.are.equal("TOKEN_FAILED", err.code)
  end)

  it("requires method-qualified route keys and dispatches only exact methods", function()
    local info = start({
      ["GET /echo"] = { body = "ok" },
    })

    local status, _, body = request_for(info, "GET", "/" .. session_token(info) .. "/echo", {}, "")
    assert.are.equal(200, status)
    assert.are.equal("ok", body)

    status, _, body = request_for(info, "POST", "/" .. session_token(info) .. "/echo", {}, "")
    assert.are.equal(404, status)
    assert.are.same({ error = { code = "NOT_FOUND", message = "not found" } }, vim.json.decode(body))

    local invalid_info, err = session._test.start({ routes = { ["/echo"] = { body = "wrong" } } })
    assert.is_nil(invalid_info)
    assert.are.equal("SERVER_FAILED", err.code)
  end)

  it("parses delimiter and binary body fragments without inspecting body newlines", function()
    local info = start({
      ["POST /echo"] = function(request_record)
        return { body = request_record.body, content_type = "application/octet-stream" }
      end,
    })
    local body = "line one\n\0\r\nline two\n"
    local head = "POST /" .. session_token(info) .. "/echo HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n"
    local raw = head .. body
    local split_one = #head - 2
    local split_two = #head + 10
    local split_three = #head + #body - 2
    local parts = {
      raw:sub(1, 17),
      raw:sub(18, split_one),
      raw:sub(split_one + 1, split_two),
      raw:sub(split_two + 1, split_three),
      raw:sub(split_three + 1),
    }

    local status, _, response_body = request(info, parts, nil, 5)

    assert.are.equal(200, status)
    assert.are.equal(body, response_body)
  end)

  it("receives exactly Content-Length bytes and ignores coalesced or later trailing data", function()
    local info = start({
      ["POST /echo"] = function(request_record)
        return { body = request_record.body, content_type = "text/plain" }
      end,
    })
    local body = "declared\n\0"
    local head = "POST /" .. session_token(info) .. "/echo HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n"

    local status, _, response_body = request(info, { head .. body .. "coalesced-trailing" })
    assert.are.equal(200, status)
    assert.are.equal(body, response_body)

    status, _, response_body = request(info, { head .. body, "later-trailing" }, nil, 20, true)
    assert.are.equal(200, status)
    assert.are.equal(body, response_body)
  end)

  it("returns structured errors for invalid framing and unsupported transfer encoding", function()
    local info = start({ ["POST /echo"] = { body = "ok" } })

    local status, _, body =
      request_for(info, "POST", "/" .. session_token(info) .. "/echo", { ["Content-Length"] = "not-a-length" }, "")
    assert.are.equal(400, status)
    assert.are.same({ error = { code = "INVALID_REQUEST", message = "invalid request" } }, vim.json.decode(body))

    status, _, body =
      request_for(info, "POST", "/" .. session_token(info) .. "/echo", { ["Transfer-Encoding"] = "chunked" }, "")
    assert.are.equal(400, status)
    assert.are.same({ error = { code = "INVALID_REQUEST", message = "invalid request" } }, vim.json.decode(body))

    status, _, body = request(info, { "GET /" .. session_token(info) .. "/echo HTTP/1.1\n\n" })
    assert.are.equal(400, status)
    assert.are.same({ error = { code = "INVALID_REQUEST", message = "invalid request" } }, vim.json.decode(body))
  end)

  it("rejects oversized request lines and headers but accepts exact limits", function()
    local exact_path = "/" .. string.rep("x", 8134)
    assert.are.equal(8135, #exact_path)
    local info = start({
      ["GET " .. exact_path] = { body = "line-limit" },
      ["GET /echo"] = { body = "header-limit" },
    })
    assert.are.equal(8192, #("GET /" .. session_token(info) .. exact_path .. " HTTP/1.1"))

    local status, _, body = request_for(info, "GET", "/" .. session_token(info) .. exact_path, {}, "")
    assert.are.equal(200, status)
    assert.are.equal("line-limit", body)

    local request_line = "GET /" .. session_token(info) .. "/echo HTTP/1.1\r\n"
    local fill_length = 32768 - #request_line - #"X-Fill: " - 4
    local exact_headers = request_line .. "X-Fill: " .. string.rep("x", fill_length) .. "\r\n\r\n"
    assert.are.equal(32768, #exact_headers)
    status, _, body = request(info, { exact_headers })
    assert.are.equal(200, status)
    assert.are.equal("header-limit", body)

    local oversized_path = "/" .. string.rep("x", 8135)
    status, _, body = request_for(info, "GET", "/" .. session_token(info) .. oversized_path, {}, "")
    assert.are.equal(400, status)
    assert.are.same({ error = { code = "INVALID_REQUEST", message = "invalid request" } }, vim.json.decode(body))

    local oversized_headers = request_line .. "X-Fill: " .. string.rep("x", fill_length + 1) .. "\r\n\r\n"
    assert.are.equal(32769, #oversized_headers)
    status, _, body = request(info, { oversized_headers })
    assert.are.equal(400, status)
    assert.are.same({ error = { code = "INVALID_REQUEST", message = "invalid request" } }, vim.json.decode(body))
  end)

  it("rejects wrong tokens, unknown routes, and traversal-like targets", function()
    local info = start({ ["GET /echo"] = { body = "ok" } })
    local targets = {
      { target = "/wrong-token/echo", status = 404, code = "NOT_FOUND", message = "not found" },
      { target = "/" .. session_token(info) .. "/missing", status = 404, code = "NOT_FOUND", message = "not found" },
      { target = "/" .. session_token(info) .. "/../echo", status = 404, code = "NOT_FOUND", message = "not found" },
      {
        target = "/" .. session_token(info) .. "/%2e%2e/echo",
        status = 404,
        code = "NOT_FOUND",
        message = "not found",
      },
      { target = "/" .. session_token(info) .. "/..\\echo", status = 404, code = "NOT_FOUND", message = "not found" },
      {
        target = "/" .. session_token(info) .. "/echo\0suffix",
        status = 400,
        code = "INVALID_REQUEST",
        message = "invalid request",
      },
    }

    for _, request_case in ipairs(targets) do
      local status, _, body = request_for(info, "GET", request_case.target, {}, "")
      assert.are.equal(request_case.status, status)
      assert.are.same({ error = { code = request_case.code, message = request_case.message } }, vim.json.decode(body))
    end
  end)

  it("sanitizes handler errors", function()
    local info = start({
      ["GET /boom"] = function()
        error("/private/path/should-not-leak")
      end,
    })

    local status, _, body = request_for(info, "GET", "/" .. session_token(info) .. "/boom", {}, "")

    assert.are.equal(500, status)
    assert.are.same({ error = { code = "INTERNAL_ERROR", message = "internal server error" } }, vim.json.decode(body))
    assert.is_nil(body:find("private", 1, true))
  end)

  it("uses the five-second runtime default and resets the timeout after activity", function()
    assert.are.equal(5000, session._test.default_idle_timeout_ms())

    local idle_info = start({ ["GET /echo"] = { body = "ok" } }, { idle_timeout_ms = 50 })
    local status, _, body = idle_request(idle_info, 1000)
    assert.are.equal(408, status)
    assert.are.same({ error = { code = "TIMEOUT", message = "request timeout" } }, vim.json.decode(body))

    local info = start({ ["GET /echo"] = { body = "ok" } }, { idle_timeout_ms = 50 })
    local raw = "GET /" .. session_token(info) .. "/echo HTTP/1.1\r\n\r\n"
    status, _, body = request(info, { raw:sub(1, 10), raw:sub(11, 20), raw:sub(21) }, 1000, 30)
    assert.are.equal(200, status)
    assert.are.equal("ok", body)
  end)

  it("closes an already-connected client and its timer during stop", function()
    local info = start({ ["GET /echo"] = { body = "ok" } })
    local client = uv.new_tcp()
    local connected = false
    local connect_error
    local eof = false

    client:connect(info.host, info.port, function(err)
      connect_error = err
      if err then
        return
      end
      connected = true
      client:read_start(function(read_error, data)
        if read_error or not data then
          eof = true
          if not client:is_closing() then
            client:close()
          end
        end
      end)
    end)
    wait_for(function()
      return connected or connect_error ~= nil
    end)
    assert.is_true(connected)
    assert.is_nil(connect_error)

    assert.is_true(session.stop())
    wait_for(function()
      return eof
    end)
    assert.is_true(eof)
  end)

  it("stops the listener and requires a connection error for new clients", function()
    local info = start({ ["GET /echo"] = { body = "ok" } })
    assert.is_true(session.stop())

    local client = uv.new_tcp()
    local callback_done = false
    local connect_error
    client:connect(info.host, info.port, function(err)
      callback_done = true
      connect_error = err
      if not client:is_closing() then
        client:close()
      end
    end)
    wait_for(function()
      return callback_done
    end)
    assert.is_not_nil(connect_error)
    assert.is_true(session.stop())
  end)
end)
