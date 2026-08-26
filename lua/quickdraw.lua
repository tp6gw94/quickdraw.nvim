local M = {}

local DEFAULT_PATH = "./assets"
local UNICODE_WHITESPACE = {
  "\194\133",
  "\194\160",
  "\225\154\128",
  "\226\128\128",
  "\226\128\129",
  "\226\128\130",
  "\226\128\131",
  "\226\128\132",
  "\226\128\133",
  "\226\128\134",
  "\226\128\135",
  "\226\128\136",
  "\226\128\137",
  "\226\128\138",
  "\226\128\168",
  "\226\128\169",
  "\226\128\175",
  "\226\129\159",
  "\227\128\128",
}
local config = { path = DEFAULT_PATH }

local function default_session_starter(options)
  return require("quickdraw.session").start(options)
end

local function default_input(options, callback)
  vim.ui.input(options, callback)
end

local function default_directory_creator(path)
  return vim.fn.mkdir(path, "p")
end

local function default_notifier(message, level, options)
  return vim.notify(message, level, options)
end

local session_starter = default_session_starter
local input_function = default_input
local directory_creator = default_directory_creator
local notifier = default_notifier

local function new_error(code, message)
  return { code = code, message = message }
end

local function has_control(value)
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 32 or byte == 127 then
      return true
    end
  end
  return false
end

local function has_whitespace(value)
  if value:find("%s") then
    return true
  end
  for _, whitespace in ipairs(UNICODE_WHITESPACE) do
    if value:find(whitespace, 1, true) then
      return true
    end
  end
  return false
end

local function validate_name(name)
  if type(name) ~= "string" then
    return nil, new_error("INVALID_NAME", "drawing name must be a string")
  end

  name = name:match("^%s*(.-)%s*$")
  if name == "" or name == "." or name == ".." or has_control(name) or has_whitespace(name) then
    return nil, new_error("INVALID_NAME", "drawing name is invalid")
  end

  for _, character in ipairs({ "/", "\\", "[", "]", "(", ")", "<", ">" }) do
    if name:find(character, 1, true) then
      return nil, new_error("INVALID_NAME", "drawing name is invalid")
    end
  end

  if name:sub(-4):lower() == ".png" then
    local stem = name:sub(1, -5)
    if stem == "" or stem == "." or stem == ".." then
      return nil, new_error("INVALID_NAME", "drawing name is invalid")
    end
    return stem .. ".png", nil
  end
  return name .. ".png", nil
end

local function validate_path(path)
  if type(path) ~= "string" or path == "" or has_control(path) then
    return nil, new_error("INVALID_PATH", "drawing path must be a non-empty path")
  end
  return path, nil
end

local function is_absolute(path)
  if path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" then
    return true
  end
  return path:match("^%a:[/\\]") ~= nil
end

local function path_separator(path)
  if path:sub(1, 2) == "//" then
    return package.config:sub(1, 1)
  end
  if path:match("^%a:[/\\]") or path:sub(1, 2) == "\\\\" then
    return "\\"
  end
  if path:find("\\", 1, true) then
    return "\\"
  end
  return "/"
end

local function normalize_path(path, separator)
  local value = path:gsub("\\", "/")
  local prefix = ""
  local absolute = false
  local minimum_parts = 0
  local rest = value

  if value:sub(1, 2) == "//" then
    prefix = "//"
    absolute = true
    minimum_parts = 2
    rest = value:sub(3)
  elseif value:match("^%a:/") then
    prefix = value:sub(1, 2) .. "/"
    absolute = true
    rest = value:sub(4)
  elseif value:sub(1, 1) == "/" then
    prefix = "/"
    absolute = true
    rest = value:sub(2)
  end

  local parts = {}
  for part in rest:gmatch("[^/]+") do
    if part == ".." then
      if #parts > minimum_parts then
        parts[#parts] = nil
      elseif not absolute then
        parts[#parts + 1] = part
      end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end

  local body = table.concat(parts, "/")
  local result
  if prefix == "/" then
    result = "/" .. body
  elseif prefix == "//" then
    result = "//" .. body
  elseif prefix ~= "" then
    result = prefix .. body
  else
    result = body
  end

  if separator == "\\" then
    result = result:gsub("/", "\\")
  end
  return result
end

local function join_path(left, right)
  if left == "" then
    return right
  end
  if right == "" then
    return left
  end
  local last = left:sub(-1)
  if last == "/" or last == "\\" then
    return left .. right
  end
  return left .. "/" .. right
end

local function document_directory(document_path)
  if
    type(document_path) ~= "string"
    or document_path == ""
    or has_control(document_path)
    or not is_absolute(document_path)
  then
    return nil, new_error("INVALID_DOCUMENT_PATH", "saved Markdown document path must be absolute")
  end

  local normalized = document_path:gsub("\\", "/")
  local slash = normalized:match("^.*()/")
  if not slash then
    return nil, new_error("INVALID_DOCUMENT_PATH", "saved Markdown document path is invalid")
  end

  local directory = normalized:sub(1, slash - 1)
  if directory == "" then
    directory = "/"
  elseif directory:match("^%a:$") then
    directory = directory .. "/"
  end
  return directory, nil
end

local function resolve_target(document_path, base_path, name)
  local base, base_error = validate_path(base_path)
  if not base then
    return nil, base_error
  end
  local filename, name_error = validate_name(name)
  if not filename then
    return nil, name_error
  end

  if is_absolute(base) then
    return normalize_path(join_path(base, filename), path_separator(base)), nil
  end

  local directory, document_error = document_directory(document_path)
  if not directory then
    return nil, document_error
  end
  local separator = path_separator(base)
  if separator == "/" then
    separator = path_separator(document_path)
  end
  return normalize_path(join_path(join_path(directory, base), filename), separator), nil
end

local function markdown_destination(_, base_path, name)
  local base, base_error = validate_path(base_path)
  if not base then
    return nil, base_error
  end
  local filename, name_error = validate_name(name)
  if not filename then
    return nil, name_error
  end

  local destination = join_path(base:gsub("\\", "/"), filename)
  local has_scheme = destination:match("^%a[%w+%.%-]*:") and not is_absolute(destination)
  if has_whitespace(destination) or destination:find("[()<>?#]") or has_scheme then
    return nil, new_error("INVALID_PATH", "drawing path cannot be represented as a supported Markdown link")
  end
  return destination, nil
end

local function is_local_link(destination)
  if type(destination) ~= "string" or destination == "" or has_control(destination) then
    return false
  end
  if has_whitespace(destination) or destination:find("[()<>?#]") then
    return false
  end
  if destination:sub(-4):lower() ~= ".png" then
    return false
  end
  local scheme = destination:match("^%a[%w+%.%-]*:")
  return not scheme or is_absolute(destination)
end

local function find_cursor_link(line, cursor_col)
  if type(line) ~= "string" or line:find("\n", 1, true) or type(cursor_col) ~= "number" then
    return nil
  end

  local search = 1
  while true do
    local start, open = line:find("!%[%]%(", search)
    if not start then
      return nil
    end
    local close = line:find(")", open + 1, true)
    if close then
      local destination = line:sub(open + 1, close - 1)
      if is_local_link(destination) then
        if cursor_col >= start - 1 and cursor_col <= close - 1 then
          return destination
        end
        search = close + 1
      else
        search = start + 1
      end
    else
      return nil
    end
  end
end

local function resolve_link_target(document_path, destination)
  if not is_local_link(destination) then
    return nil, new_error("INVALID_PATH", "unsupported Markdown image destination")
  end
  if is_absolute(destination) then
    return normalize_path(destination, path_separator(destination)), nil
  end

  local directory, document_error = document_directory(document_path)
  if not directory then
    return nil, document_error
  end
  return normalize_path(join_path(directory, destination), path_separator(document_path)), nil
end

local function call_session(target, create)
  local options = { path = target }
  if create then
    options.create = true
  end
  local ok, info, session_error = pcall(session_starter, options)
  if not ok then
    return nil, new_error("SESSION_FAILED", "Quickdraw session could not be started")
  end
  if session_error then
    return nil, session_error
  end
  if not info then
    return nil, new_error("SESSION_FAILED", "Quickdraw session could not be started")
  end
  return info, nil
end

local function open_link(line, cursor_col, document_path)
  local destination = find_cursor_link(line, cursor_col)
  if not destination then
    return nil, nil
  end
  local target, target_error = resolve_link_target(document_path, destination)
  if not target then
    return nil, target_error
  end
  return call_session(target)
end

local function capture_context()
  local window = vim.api.nvim_get_current_win()
  local buffer = vim.api.nvim_win_get_buf(window)
  local cursor = vim.api.nvim_win_get_cursor(window)
  local row = cursor[1] - 1
  local line = vim.api.nvim_buf_get_lines(buffer, row, row + 1, false)[1] or ""
  local name = vim.api.nvim_buf_get_name(buffer)
  local document_path
  if name ~= "" then
    local absolute_name = vim.fn.fnamemodify(name, ":p")
    if not is_absolute(absolute_name) then
      return nil, new_error("INVALID_DOCUMENT_PATH", "saved Markdown document path must be absolute")
    end
    document_path = absolute_name
  end

  if vim.api.nvim_buf_get_option(buffer, "filetype") ~= "markdown" then
    return nil, new_error("UNSUPPORTED_BUFFER", "Quickdraw requires a Markdown buffer")
  end

  return {
    buffer = buffer,
    window = window,
    row = row,
    cursor_col = cursor[2],
    line = line,
    buffer_name = name,
    document_path = document_path,
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
  },
    nil
end

local function validate_context(context)
  if not vim.api.nvim_buf_is_valid(context.buffer) or not vim.api.nvim_buf_is_loaded(context.buffer) then
    return nil, new_error("BUFFER_UNAVAILABLE", "the Markdown buffer is no longer available")
  end
  if not vim.api.nvim_win_is_valid(context.window) or vim.api.nvim_win_get_buf(context.window) ~= context.buffer then
    return nil, new_error("BUFFER_WINDOW_CHANGED", "the Markdown window changed while waiting for input")
  end
  if vim.api.nvim_buf_get_name(context.buffer) ~= context.buffer_name then
    return nil, new_error("BUFFER_RENAMED", "the Markdown buffer was renamed while waiting for input")
  end
  if vim.api.nvim_buf_get_changedtick(context.buffer) ~= context.changedtick then
    return nil, new_error("BUFFER_CHANGED", "the Markdown buffer changed while waiting for input")
  end
  if vim.api.nvim_buf_get_lines(context.buffer, context.row, context.row + 1, false)[1] ~= context.line then
    return nil, new_error("BUFFER_CHANGED", "the Markdown buffer changed while waiting for input")
  end
  if not vim.api.nvim_buf_get_option(context.buffer, "modifiable") then
    return nil, new_error("BUFFER_NOT_MODIFIABLE", "the Markdown buffer is not modifiable")
  end
  return true, nil
end

local function parent_directory(path)
  local separator_index = path:match("^.*()[/\\\\]")
  if not separator_index then
    return nil
  end
  local parent = path:sub(1, separator_index - 1)
  if parent == "" then
    return path:sub(1, 1)
  end
  if parent:match("^%a:$") then
    return parent .. path:sub(separator_index, separator_index)
  end
  return parent
end

local function create_drawing(context, name)
  if type(name) ~= "string" or name:match("^%s*(.-)%s*$") == "" then
    return nil, nil
  end
  local filename, name_error = validate_name(name)
  if not filename then
    return nil, name_error
  end

  local target, target_error = resolve_target(context.document_path, config.path, filename)
  if not target then
    return nil, target_error
  end
  local destination, destination_error = markdown_destination(context.document_path, config.path, filename)
  if not destination then
    return nil, destination_error
  end

  local valid, context_error = validate_context(context)
  if not valid then
    return nil, context_error
  end

  local parent = parent_directory(target)
  if not parent then
    return nil, new_error("MKDIR_FAILED", "drawing directory could not be determined")
  end
  local mkdir_ok, mkdir_result = pcall(directory_creator, parent)
  if not mkdir_ok or (mkdir_result ~= true and mkdir_result ~= 1) then
    return nil, new_error("MKDIR_FAILED", "drawing directory could not be created")
  end

  local info, session_error = call_session(target, true)
  if not info then
    return nil, session_error
  end

  valid, context_error = validate_context(context)
  if not valid then
    return nil, context_error
  end

  local inserted =
    pcall(vim.api.nvim_buf_set_text, context.buffer, context.row, context.cursor_col, context.row, context.cursor_col, {
      "![](" .. destination .. ")",
    })
  if not inserted then
    return nil, new_error("INSERT_FAILED", "the Markdown image link could not be inserted")
  end
  return info, nil
end

local function complete(on_complete, info, command_error)
  if on_complete then
    on_complete(info, command_error)
  end
  return info, command_error
end

local function run(on_complete)
  local context, context_error = capture_context()
  if not context then
    return complete(on_complete, nil, context_error)
  end

  local destination = find_cursor_link(context.line, context.cursor_col)
  if destination then
    local info, edit_error = open_link(context.line, context.cursor_col, context.document_path)
    return complete(on_complete, info, edit_error)
  end

  local ok, input_error = pcall(input_function, { prompt = "Drawing name: " }, function(name)
    local info, create_error = create_drawing(context, name)
    complete(on_complete, info, create_error)
  end)
  if not ok then
    return complete(on_complete, nil, new_error("INPUT_FAILED", "drawing name input could not be opened"))
  end
  return true, nil
end

local function notify(message, level)
  pcall(notifier, message, level, { title = "quickdraw.nvim" })
end

local function safe_error_message(command_error)
  local message = type(command_error) == "table" and command_error.message
  if type(message) ~= "string" or message == "" then
    return "Quickdraw operation failed"
  end
  return (message:gsub("https?://%S+", "[URL omitted]"))
end

local function command_complete(info, command_error)
  if command_error then
    notify(safe_error_message(command_error), vim.log.levels.ERROR)
  elseif
    type(info) == "table"
    and info.browser_opened == false
    and type(info.url) == "string"
    and type(info.warning) == "table"
    and info.warning.code == "BROWSER_OPEN_FAILED"
  then
    notify("Open this URL in your browser: " .. info.url, vim.log.levels.WARN)
  end
end

local function run_command()
  return run(command_complete)
end

local function validate_options(options)
  if options == nil then
    options = {}
  end
  if type(options) ~= "table" then
    error("quickdraw.setup expects a table", 3)
  end

  for key in pairs(options) do
    if key ~= "path" then
      error("quickdraw.setup received an unknown option", 3)
    end
  end

  local path, path_error = validate_path(options.path == nil and DEFAULT_PATH or options.path)
  if not path then
    error(path_error.message, 3)
  end
  local destination, destination_error = markdown_destination(nil, path, "drawing")
  if not destination then
    error(destination_error.message, 3)
  end
  return { path = path }
end

function M.setup(options)
  local next_config = validate_options(options)
  config = next_config
end

M._run = run
M._command = run_command

M._test = {
  config = function()
    return { path = config.path }
  end,
  find_cursor_link = find_cursor_link,
  markdown_destination = markdown_destination,
  open_link = open_link,
  reset = function()
    config = { path = DEFAULT_PATH }
    session_starter = default_session_starter
    input_function = default_input
    directory_creator = default_directory_creator
    notifier = default_notifier
  end,
  resolve_target = resolve_target,
  run = run,
  set_directory_creator = function(creator)
    directory_creator = creator or default_directory_creator
  end,
  set_input = function(input)
    input_function = input
  end,
  set_notifier = function(next_notifier)
    notifier = next_notifier or default_notifier
  end,
  set_session_starter = function(starter)
    session_starter = starter
  end,
  validate_name = validate_name,
}

return M
