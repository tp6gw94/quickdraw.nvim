local quickdraw = require("quickdraw")

describe("quickdraw configuration and paths", function()
  before_each(function()
    quickdraw._test.reset()
  end)

  it("uses the default path", function()
    assert.are.same({ path = "./assets" }, quickdraw._test.config())
  end)

  it("replaces configuration from defaults", function()
    quickdraw.setup({ path = "/tmp/drawings" })
    quickdraw.setup({})

    assert.are.same({ path = "./assets" }, quickdraw._test.config())
  end)

  it("rejects invalid configuration atomically", function()
    quickdraw.setup({ path = "/tmp/drawings" })

    local ok = pcall(function()
      quickdraw.setup({ path = "" })
    end)
    assert.is_false(ok)
    assert.are.same({ path = "/tmp/drawings" }, quickdraw._test.config())

    ok = pcall(function()
      quickdraw.setup({ path = "/tmp/drawings", extra = true })
    end)
    assert.is_false(ok)
    assert.are.same({ path = "/tmp/drawings" }, quickdraw._test.config())

    ok = pcall(function()
      quickdraw.setup({ path = false })
    end)
    assert.is_false(ok)
    assert.are.same({ path = "/tmp/drawings" }, quickdraw._test.config())
  end)

  it("rejects configured paths that cannot form a supported link", function()
    quickdraw.setup({ path = "/tmp/drawings" })

    for _, path in ipairs({ "my assets", "assets(test)", "assets<test>", "assets?test", "assets#test", "https:assets" }) do
      local ok = pcall(quickdraw.setup, { path = path })
      assert.is_false(ok, path)
      assert.are.same({ path = "/tmp/drawings" }, quickdraw._test.config())
    end
  end)

  it("accepts a Unicode basename and normalizes its suffix", function()
    local filename = assert(quickdraw._test.validate_name("  画布.PNG  "))

    assert.are.equal("画布.png", filename)
  end)

  it("appends the suffix when it is absent", function()
    assert.are.equal("diagram.png", quickdraw._test.validate_name("diagram"))
    assert.are.equal("diagram.png", quickdraw._test.validate_name("diagram.png"))
  end)

  it("rejects unsafe or empty basenames", function()
    local invalid_names = {
      "",
      "   ",
      ".",
      "..",
      ".png",
      ".PNG",
      "a/b",
      "a\\b",
      "a\0b",
      "a\nb",
      "a b",
      "a b",
      "a[b",
      "a]b",
      "a(b",
      "a)b",
      "a<b",
      "a>b",
    }

    for _, name in ipairs(invalid_names) do
      local filename, err = quickdraw._test.validate_name(name)
      assert.is_nil(filename, name)
      assert.are.equal("INVALID_NAME", err.code)
    end
  end)

  it("resolves a relative target from the Markdown document directory", function()
    local target, err = quickdraw._test.resolve_target("/workspace/notes/readme.md", "./assets", "diagram")
    assert.is_nil(err)
    assert.are.equal("/workspace/notes/assets/diagram.png", target)

    local destination
    destination, err = quickdraw._test.markdown_destination("/workspace/notes/readme.md", "./assets", "diagram")
    assert.is_nil(err)
    assert.are.equal("./assets/diagram.png", destination)
  end)

  it("does not require the document directory for an absolute target", function()
    local target, err = quickdraw._test.resolve_target(nil, "/var/lib/drawings", "diagram.png")
    assert.is_nil(err)
    assert.are.equal("/var/lib/drawings/diagram.png", target)

    local destination
    destination, err = quickdraw._test.markdown_destination(nil, "/var/lib/drawings", "diagram.png")
    assert.is_nil(err)
    assert.are.equal("/var/lib/drawings/diagram.png", destination)
  end)

  it("rejects missing or relative document paths for relative targets", function()
    for _, document_path in ipairs({ false, "", "notes/readme.md" }) do
      local target, err =
        quickdraw._test.resolve_target(document_path == false and nil or document_path, "./assets", "diagram")

      assert.is_nil(target)
      assert.are.equal("INVALID_DOCUMENT_PATH", err.code)
    end
  end)

  it("ignores global, tab-local, and window-local working directories", function()
    local original_directory = vim.fn.getcwd()
    local directories = { vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname() }
    for _, directory in ipairs(directories) do
      assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    end

    vim.cmd("tabnew")
    local ok, err = pcall(function()
      local expected = "/workspace/notes/assets/diagram.png"
      vim.cmd("cd " .. vim.fn.fnameescape(directories[1]))
      assert.are.equal(expected, quickdraw._test.resolve_target("/workspace/notes/readme.md", "./assets", "diagram"))
      vim.cmd("tcd " .. vim.fn.fnameescape(directories[2]))
      assert.are.equal(expected, quickdraw._test.resolve_target("/workspace/notes/readme.md", "./assets", "diagram"))
      vim.cmd("lcd " .. vim.fn.fnameescape(directories[3]))
      assert.are.equal(expected, quickdraw._test.resolve_target("/workspace/notes/readme.md", "./assets", "diagram"))
    end)
    vim.cmd("tabclose!")
    vim.cmd("cd " .. vim.fn.fnameescape(original_directory))
    for _, directory in ipairs(directories) do
      vim.fn.delete(directory, "rf")
    end
    assert.is_true(ok, err)
  end)

  it("keeps Windows drive paths absolute", function()
    local target, err = quickdraw._test.resolve_target("C:\\workspace\\readme.md", ".\\assets", "diagram")
    assert.is_nil(err)
    assert.are.equal("C:\\workspace\\assets\\diagram.png", target)

    local destination
    destination, err = quickdraw._test.markdown_destination("C:\\workspace\\readme.md", ".\\assets", "diagram")
    assert.is_nil(err)
    assert.are.equal("./assets/diagram.png", destination)

    target, err = quickdraw._test.resolve_target("C:\\workspace\\readme.md", "C:\\drawings", "diagram")
    assert.is_nil(err)
    assert.are.equal("C:\\drawings\\diagram.png", target)

    destination, err = quickdraw._test.markdown_destination("C:\\workspace\\readme.md", "C:\\drawings", "diagram")
    assert.is_nil(err)
    assert.are.equal("C:/drawings/diagram.png", destination)
  end)

  it("does not treat non-letter drive prefixes as absolute", function()
    local target, err = quickdraw._test.resolve_target("/workspace/readme.md", "1:/drawings", "diagram")
    assert.is_nil(err)
    assert.are.equal("/workspace/1:/drawings/diagram.png", target)

    target, err = quickdraw._test.resolve_target("/workspace/readme.md", "?:\\drawings", "diagram")
    assert.is_nil(err)
    assert.are.equal("\\workspace\\?:\\drawings\\diagram.png", target)
  end)

  it("keeps UNC paths absolute", function()
    local target, err = quickdraw._test.resolve_target("\\\\server\\share\\notes\\readme.md", ".\\assets", "diagram")
    assert.is_nil(err)
    assert.are.equal("\\\\server\\share\\notes\\assets\\diagram.png", target)

    target, err =
      quickdraw._test.resolve_target("\\\\server\\share\\notes\\readme.md", "\\\\server\\share\\drawings", "diagram")
    assert.is_nil(err)
    assert.are.equal("\\\\server\\share\\drawings\\diagram.png", target)

    local destination
    destination, err = quickdraw._test.markdown_destination(nil, "\\\\server\\share\\drawings", "diagram")
    assert.is_nil(err)
    assert.are.equal("//server/share/drawings/diagram.png", destination)
  end)

  it("does not expand home, environment, or glob syntax", function()
    local literal_path = "~/assets/$DRAWINGS/*"
    quickdraw.setup({ path = literal_path })
    assert.are.same({ path = literal_path }, quickdraw._test.config())

    local target, err = quickdraw._test.resolve_target("/workspace/readme.md", literal_path, "diagram")
    assert.is_nil(err)
    assert.are.equal("/workspace/~/assets/$DRAWINGS/*/diagram.png", target)

    local destination
    destination, err = quickdraw._test.markdown_destination("/workspace/readme.md", literal_path, "diagram")
    assert.is_nil(err)
    assert.are.equal("~/assets/$DRAWINGS/*/diagram.png", destination)
  end)

  it("rejects generated destinations the cursor scanner cannot reopen", function()
    for _, path in ipairs({ "my assets", "assets(test)", "assets<test>", "assets?test", "assets#test", "https:assets" }) do
      local destination, err = quickdraw._test.markdown_destination("/workspace/readme.md", path, "diagram")
      assert.is_nil(destination, path)
      assert.are.equal("INVALID_PATH", err.code)
    end
  end)
end)

describe("quickdraw linked image editing", function()
  local calls

  before_each(function()
    quickdraw._test.reset()
    calls = {}
    quickdraw._test.set_session_starter(function(options)
      calls[#calls + 1] = options
      return { started = true }, nil
    end)
  end)

  after_each(function()
    quickdraw._test.reset()
  end)

  it("finds every cursor position in a generated image and starts one session", function()
    local line = "前文 ![](first.PNG) 中 ![](./second.png) 後文"
    local first_start, first_end = line:find("!%[%]%(%S+%)")
    local second_start, second_end = line:find("!%[%]%(%S+%)", first_end + 1)

    assert.are.equal("first.PNG", quickdraw._test.find_cursor_link(line, first_start - 1))
    assert.are.equal("./second.png", quickdraw._test.find_cursor_link(line, second_end - 1))
    for cursor = first_start - 1, first_end - 1 do
      local info, err = quickdraw._test.open_link(line, cursor, "/workspace/notes/readme.md")
      assert.is_nil(err)
      assert.is_table(info)
    end
    local first_call_count = first_end - first_start + 1
    assert.are.equal(first_call_count, #calls)
    assert.are.equal("/workspace/notes/first.PNG", calls[1].path)

    local info, err = quickdraw._test.open_link(line, second_start - 1, "/workspace/notes/readme.md")
    assert.is_nil(err)
    assert.is_table(info)
    assert.are.equal(first_call_count + 1, #calls)
    assert.are.equal("/workspace/notes/second.png", calls[first_call_count + 1].path)
  end)

  it("resolves local absolute and Windows destinations", function()
    local cases = {
      {
        line = "![](/var/drawings/diagram.png)",
        document = nil,
        expected = "/var/drawings/diagram.png",
      },
      {
        line = "![](C:\\drawings\\diagram.PNG)",
        document = "C:\\workspace\\notes\\readme.md",
        expected = "C:\\drawings\\diagram.PNG",
      },
      {
        line = "![](../assets/diagram.png)",
        document = "C:\\workspace\\notes\\readme.md",
        expected = "C:\\workspace\\assets\\diagram.png",
      },
      {
        line = "![](\\\\server\\share\\diagram.png)",
        document = "C:\\workspace\\notes\\readme.md",
        expected = "\\\\server\\share\\diagram.png",
      },
      {
        line = "![](../assets/diagram.png)",
        document = "\\\\server\\share\\notes\\readme.md",
        expected = "\\\\server\\share\\assets\\diagram.png",
      },
    }

    for _, case in ipairs(cases) do
      local info, err = quickdraw._test.open_link(case.line, 0, case.document)
      assert.is_nil(err)
      assert.is_table(info)
      assert.are.equal(case.expected, calls[#calls].path)
    end
    assert.are.equal(#cases, #calls)
  end)

  it("reopens the forward-slash UNC destination generated for Markdown", function()
    local destination = assert(quickdraw._test.markdown_destination(nil, "\\\\server\\share\\drawings", "diagram"))
    assert.are.equal("//server/share/drawings/diagram.png", destination)

    local info, err = quickdraw._test.open_link("![](" .. destination .. ")", 0, "C:\\notes\\readme.md")

    local expected = package.config:sub(1, 1) == "\\" and "\\\\server\\share\\drawings\\diagram.png"
      or "//server/share/drawings/diagram.png"
    assert.is_nil(err)
    assert.is_table(info)
    assert.are.same({ path = expected }, calls[1])
  end)

  it("returns named session outcomes unchanged and calls once per edit", function()
    local outcomes = {
      { error = { code = "NOT_QUICKDRAW", message = "existing PNG has no Quickdraw metadata" } },
      { error = { code = "INVALID_CRC", message = "PNG chunk CRC is invalid" } },
      {
        info = {
          browser_opened = false,
          url = "http://127.0.0.1/token/",
          warning = { code = "BROWSER_OPEN_FAILED", message = "default browser could not be opened" },
        },
      },
    }
    local next_outcome = 0
    quickdraw._test.set_session_starter(function(options)
      calls[#calls + 1] = options
      next_outcome = next_outcome + 1
      local outcome = outcomes[next_outcome]
      return outcome.info, outcome.error
    end)

    for _, outcome in ipairs(outcomes) do
      local info, err = quickdraw._test.open_link("![](diagram.png)", 0, "/workspace/readme.md")
      assert.are.equal(outcome.info, info)
      assert.are.equal(outcome.error, err)
    end
    assert.are.equal(#outcomes, #calls)
    assert.are.same({ path = "/workspace/diagram.png" }, calls[1])
  end)

  it("returns no supported link for unsupported Markdown and destinations", function()
    local lines = {
      "![diagram](diagram.png)",
      '![](diagram.png \\"title\\")',
      "![](<diagram.png>)",
      "![](diagram.png?raw=1)",
      "![](diagram.png#fragment)",
      "![](https://example.test/diagram.png)",
      "![](mailto:diagram.png)",
      "![](C:diagram.png)",
      "![](nested(foo).png)",
      "![](a b.png)",
      "![](diagram.png",
      "[diagram][reference]",
      "![](diagram.png)\n![](other.png)",
    }

    for _, line in ipairs(lines) do
      local info, err = quickdraw._test.open_link(line, 0, "/workspace/readme.md")
      assert.is_nil(info, line)
      assert.is_nil(err, line)
    end
    assert.are.equal(0, #calls)
  end)

  it("finds a valid image after an unsupported opener", function()
    local line = "![](broken ![](good.png)"
    local valid_start = assert(line:find("!%[%]%(%w+%.png%)", 2))

    local info, err = quickdraw._test.open_link(line, valid_start - 1, "/workspace/readme.md")

    assert.is_nil(err)
    assert.is_table(info)
    assert.are.same({ path = "/workspace/good.png" }, calls[1])
  end)
end)

describe("quickdraw create workflow", function()
  local buffer
  local prompt_callback
  local prompt_calls
  local mkdir_calls
  local session_calls
  local reports
  local events

  local function new_markdown_buffer(lines, name)
    buffer = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_option(buffer, "swapfile", false)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    if name then
      vim.api.nvim_buf_set_name(buffer, name)
    end
    vim.api.nvim_buf_set_option(buffer, "filetype", "markdown")
    vim.api.nvim_set_current_buf(buffer)
    return buffer
  end

  local function run()
    reports = {}
    return quickdraw._test.run(function(info, err)
      reports[#reports + 1] = { info = info, error = err }
    end)
  end

  before_each(function()
    quickdraw._test.reset()
    prompt_callback = nil
    prompt_calls = {}
    mkdir_calls = {}
    session_calls = {}
    reports = {}
    events = {}
    quickdraw._test.set_input(function(options, callback)
      prompt_calls[#prompt_calls + 1] = options
      prompt_callback = callback
    end)
    quickdraw._test.set_directory_creator(function(path)
      mkdir_calls[#mkdir_calls + 1] = path
      events[#events + 1] = "mkdir"
      return 1
    end)
    quickdraw._test.set_session_starter(function(options)
      session_calls[#session_calls + 1] = options
      events[#events + 1] = "session"
      return { url = "http://127.0.0.1:1234/token/", browser_opened = true }, nil
    end)
  end)

  after_each(function()
    quickdraw._test.reset()
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
    buffer = nil
  end)

  it("cancels and ignores trimmed-empty names without side effects", function()
    new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    run()
    assert.are.equal(1, #prompt_calls)
    prompt_callback(nil)
    prompt_callback("   ")

    assert.are.equal(0, #mkdir_calls)
    assert.are.equal(0, #session_calls)
    assert.are.equal("text", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
    assert.are.equal(2, #reports)
    assert.is_nil(reports[1].info)
    assert.is_nil(reports[1].error)
    assert.is_nil(reports[2].info)
    assert.is_nil(reports[2].error)
  end)

  it("reports invalid names without side effects", function()
    new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    run()
    prompt_callback("bad/name")

    assert.are.equal(0, #mkdir_calls)
    assert.are.equal(0, #session_calls)
    assert.are.equal("INVALID_NAME", reports[1].error.code)
    assert.are.equal("text", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
  end)

  it("rejects relative creation from an unnamed Markdown buffer", function()
    new_markdown_buffer({ "text" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    run()
    prompt_callback("diagram")

    assert.are.equal(0, #mkdir_calls)
    assert.are.equal(0, #session_calls)
    assert.are.equal("INVALID_DOCUMENT_PATH", reports[1].error.code)
  end)

  it("allows absolute configured creation from an unnamed Markdown buffer", function()
    local directory = vim.fn.tempname()
    quickdraw.setup({ path = directory })
    new_markdown_buffer({ "text" })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    run()
    prompt_callback("diagram")

    local expected_target = assert(quickdraw._test.resolve_target(nil, directory, "diagram"))
    local expected_destination = assert(quickdraw._test.markdown_destination(nil, directory, "diagram"))
    assert.are.same({ directory }, mkdir_calls)
    assert.are.same({ { path = expected_target, create = true } }, session_calls)
    assert.are.equal("tex![](" .. expected_destination .. ")t", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
    assert.are.same({ "mkdir", "session" }, events)
    assert.are.equal(1, #reports)
    assert.is_table(reports[1].info)
    assert.is_nil(reports[1].error)
  end)

  it("reports directory creation failure before starting a session", function()
    quickdraw.setup({ path = "/tmp/quickdraw/assets" })
    quickdraw._test.set_directory_creator(function(path)
      mkdir_calls[#mkdir_calls + 1] = path
      return 0
    end)
    new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    run()
    prompt_callback("diagram")

    assert.are.equal(1, #mkdir_calls)
    assert.are.equal(0, #session_calls)
    assert.are.equal("MKDIR_FAILED", reports[1].error.code)
    assert.are.equal("text", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
  end)

  it("guards asynchronous callbacks against changed buffers and windows", function()
    local cases = {
      {
        name = "changed text",
        mutate = function()
          vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "changed" })
        end,
        code = "BUFFER_CHANGED",
      },
      {
        name = "non-modifiable buffer",
        mutate = function()
          vim.api.nvim_buf_set_option(buffer, "modifiable", false)
        end,
        code = "BUFFER_NOT_MODIFIABLE",
      },
      {
        name = "unloaded buffer",
        mutate = function()
          vim.api.nvim_buf_delete(buffer, { force = true })
        end,
        code = "BUFFER_UNAVAILABLE",
      },
      {
        name = "different window buffer",
        mutate = function()
          local other = vim.api.nvim_create_buf(false, false)
          vim.api.nvim_buf_set_option(other, "swapfile", false)
          vim.api.nvim_set_current_buf(other)
        end,
        code = "BUFFER_WINDOW_CHANGED",
      },
      {
        name = "renamed buffer",
        mutate = function()
          vim.api.nvim_buf_set_name(buffer, "/tmp/quickdraw-renamed.md")
        end,
        code = "BUFFER_RENAMED",
      },
    }

    for _, case in ipairs(cases) do
      quickdraw._test.reset()
      prompt_callback = nil
      prompt_calls = {}
      mkdir_calls = {}
      session_calls = {}
      reports = {}
      quickdraw._test.set_input(function(options, callback)
        prompt_callback = callback
      end)
      quickdraw._test.set_directory_creator(function(path)
        mkdir_calls[#mkdir_calls + 1] = path
        return 1
      end)
      quickdraw._test.set_session_starter(function(options)
        session_calls[#session_calls + 1] = options
        return {}, nil
      end)
      if buffer and vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
      buffer = new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
      vim.api.nvim_win_set_cursor(0, { 1, 4 })

      run()
      case.mutate()
      prompt_callback("diagram")

      assert.are.equal(0, #mkdir_calls, case.name)
      assert.are.equal(0, #session_calls, case.name)
      assert.are.equal(case.code, reports[1].error.code, case.name)
    end
  end)

  it("inserts after session success at a Unicode byte cursor", function()
    new_markdown_buffer({ "前文" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, #"前文" })
    quickdraw._test.set_session_starter(function(options)
      assert.are.equal("前文", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
      session_calls[#session_calls + 1] = options
      events[#events + 1] = "session"
      return { browser_opened = true }, nil
    end)

    run()
    prompt_callback("  diagram.PNG  ")

    assert.are.equal("前![](./assets/diagram.png)文", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
    assert.are.same({ "mkdir", "session" }, events)
    local expected_target =
      assert(quickdraw._test.resolve_target(vim.api.nvim_buf_get_name(buffer), "./assets", "diagram"))
    assert.are.equal(expected_target, session_calls[1].path)
    assert.is_true(session_calls[1].create)
    assert.is_true(vim.api.nvim_buf_get_option(buffer, "modified"))
    assert.is_nil(reports[1].error)
  end)

  it("does not insert when session startup fails", function()
    new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    local session_error = { code = "NOT_QUICKDRAW", message = "existing PNG is not editable" }
    quickdraw._test.set_session_starter(function(options)
      session_calls[#session_calls + 1] = options
      return nil, session_error
    end)

    run()
    prompt_callback("diagram")

    assert.are.equal(1, #mkdir_calls)
    assert.are.equal(1, #session_calls)
    assert.is_true(session_calls[1].create)
    assert.are.equal(session_error, reports[1].error)
    assert.are.equal("text", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
  end)

  it("reports a same-name conflict without reopening the prompt", function()
    new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    local session_error = {
      code = "TARGET_EXISTS",
      message = "A drawing with that name already exists. Choose another name.",
    }
    quickdraw._test.set_session_starter(function(options)
      session_calls[#session_calls + 1] = options
      return nil, session_error
    end)

    run()
    prompt_callback("diagram")

    assert.are.equal(1, #prompt_calls)
    local expected_target =
      assert(quickdraw._test.resolve_target(vim.api.nvim_buf_get_name(buffer), "./assets", "diagram"))
    assert.are.same({ { path = expected_target, create = true } }, session_calls)
    assert.are.equal(session_error, reports[1].error)
    assert.are.equal("text", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
  end)

  it("revalidates the buffer after session success", function()
    local cases = {
      {
        mutate = function()
          vim.api.nvim_buf_set_option(buffer, "modifiable", false)
        end,
        code = "BUFFER_NOT_MODIFIABLE",
      },
      {
        mutate = function()
          vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "changed by session" })
        end,
        code = "BUFFER_CHANGED",
      },
    }

    for _, case in ipairs(cases) do
      if buffer and vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
      buffer = new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      reports = {}
      session_calls = {}
      quickdraw._test.set_session_starter(function(options)
        session_calls[#session_calls + 1] = options
        case.mutate()
        return { browser_opened = true }, nil
      end)

      run()
      prompt_callback("diagram")

      assert.are.equal(1, #session_calls)
      assert.are.equal(case.code, reports[1].error.code)
      assert.is_nil(reports[1].info)
    end
  end)

  it("creates a missing directory and accepts it when it already exists", function()
    local root = vim.fn.tempname()
    local directory = root .. "/nested/assets"
    quickdraw.setup({ path = directory })
    quickdraw._test.set_directory_creator(nil)
    new_markdown_buffer({ "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    run()
    prompt_callback("first")
    assert.are.equal(1, vim.fn.isdirectory(directory))

    local first_line = vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]
    vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    run()
    prompt_callback("second")

    assert.are.equal(1, vim.fn.isdirectory(directory))
    assert.is_not.equal(first_line, vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
    vim.fn.delete(root, "rf")
  end)

  it("inserts when browser launch only returns a warning", function()
    new_markdown_buffer({ "text" }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    local warning = { code = "BROWSER_OPEN_FAILED", message = "default browser could not be opened" }
    local info = { url = "http://127.0.0.1:1234/token/", browser_opened = false, warning = warning }
    quickdraw._test.set_session_starter(function(options)
      session_calls[#session_calls + 1] = options
      return info, nil
    end)

    run()
    prompt_callback("diagram")

    assert.are.equal("tex![](./assets/diagram.png)t", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
    assert.are.equal(info, reports[1].info)
    assert.is_nil(reports[1].error)
  end)

  it("edits a supported image synchronously without prompting or mutation", function()
    local line = "![](./assets/existing.png)"
    new_markdown_buffer({ line }, "/tmp/quickdraw-note.md")
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    quickdraw._test.set_input(function()
      error("edit branch must not prompt")
    end)

    run()

    assert.are.equal(0, #prompt_calls)
    assert.are.equal(1, #session_calls)
    assert.are.same({
      path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buffer), ":p:h") .. "/assets/existing.png",
    }, session_calls[1])
    assert.are.equal(line, vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
    assert.is_nil(reports[1].error)
  end)
end)

describe("quickdraw command boundary", function()
  local buffer
  local prompt_callback
  local notifications

  local function remove_command(name)
    pcall(vim.api.nvim_del_user_command, name)
  end

  local function source_plugin()
    vim.g.loaded_quickdraw = nil
    vim.cmd("runtime plugin/quickdraw.lua")
  end

  local function new_buffer(filetype, name, line)
    buffer = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_option(buffer, "swapfile", false)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { line or "text" })
    if name then
      vim.api.nvim_buf_set_name(buffer, name)
    end
    vim.api.nvim_buf_set_option(buffer, "filetype", filetype)
    vim.api.nvim_set_current_buf(buffer)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end

  local function command()
    return vim.api.nvim_get_commands({ builtin = false }).Quickdraw
  end

  before_each(function()
    quickdraw._test.reset()
    notifications = {}
    prompt_callback = nil
    quickdraw._test.set_notifier(function(message, level, options)
      notifications[#notifications + 1] = { message = message, level = level, options = options }
    end)
    vim.g.loaded_quickdraw = nil
    remove_command("Quickdraw")
  end)

  after_each(function()
    quickdraw._test.reset()
    vim.g.loaded_quickdraw = nil
    remove_command("Quickdraw")
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
    buffer = nil
  end)

  it("registers one described argument-free command and tolerates double sourcing", function()
    source_plugin()
    local first = command()
    assert.is_table(first)
    assert.are.equal("Quickdraw", first.name)
    assert.are.equal("0", first.nargs)
    assert.are.equal("Create or edit a Quickdraw drawing", first.definition)

    local ok, err = pcall(vim.cmd, "runtime plugin/quickdraw.lua")
    assert.is_true(ok, err)
    local second = command()
    assert.are.equal(first.name, second.name)
    assert.are.equal(first.nargs, second.nargs)
    assert.are.equal(first.definition, second.definition)
  end)

  it("rejects command arguments before invoking the workflow", function()
    source_plugin()

    local ok = pcall(vim.cmd, "Quickdraw unexpected")

    assert.is_false(ok)
    assert.are.equal(0, #notifications)
  end)

  it("notifies a non-Markdown error with a safe title and level", function()
    source_plugin()
    new_buffer("text", "/tmp/quickdraw-command.txt")

    vim.cmd("Quickdraw")

    assert.are.equal(1, #notifications)
    assert.are.equal("Quickdraw requires a Markdown buffer", notifications[1].message)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.are.equal("quickdraw.nvim", notifications[1].options.title)
  end)

  it("notifies validation, input, and session errors without leaking URLs", function()
    source_plugin()
    new_buffer("markdown", "/tmp/quickdraw-command.md")
    quickdraw._test.set_input(function(_, callback)
      prompt_callback = callback
    end)

    vim.cmd("Quickdraw")
    prompt_callback("bad/name")
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.are.equal("quickdraw.nvim", notifications[1].options.title)
    assert.is_truthy(notifications[1].message:find("drawing name is invalid", 1, true))

    notifications = {}
    quickdraw._test.set_input(function()
      error("input http://127.0.0.1:4321/unrelated-token/")
    end)
    vim.cmd("Quickdraw")
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_falsy(notifications[1].message:find("unrelated-token", 1, true))
    assert.is_falsy(notifications[1].message:find("http://", 1, true))

    notifications = {}
    quickdraw._test.set_input(function(_, callback)
      prompt_callback = callback
    end)
    quickdraw._test.set_directory_creator(function()
      return 1
    end)
    quickdraw._test.set_session_starter(function()
      return nil,
        {
          code = "SESSION_FAILED",
          message = "session failed at http://127.0.0.1:4321/unrelated-token/",
        }
    end)
    vim.cmd("Quickdraw")
    prompt_callback("diagram")
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.is_falsy(notifications[1].message:find("unrelated-token", 1, true))
    assert.is_falsy(notifications[1].message:find("http://", 1, true))
  end)

  it("shows the replacement-name reason for a same-name conflict", function()
    source_plugin()
    new_buffer("markdown", "/tmp/quickdraw-command.md")
    quickdraw._test.set_input(function(_, callback)
      prompt_callback = callback
    end)
    quickdraw._test.set_directory_creator(function()
      return 1
    end)
    quickdraw._test.set_session_starter(function()
      return nil,
        {
          code = "TARGET_EXISTS",
          message = "A drawing with that name already exists. Choose another name.",
        }
    end)

    vim.cmd("Quickdraw")
    prompt_callback("diagram")

    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
    assert.are.equal("A drawing with that name already exists. Choose another name.", notifications[1].message)
    assert.are.equal("quickdraw.nvim", notifications[1].options.title)
  end)

  it("keeps successful create and edit commands silent", function()
    source_plugin()
    new_buffer("markdown", "/tmp/quickdraw-command.md")
    quickdraw._test.set_input(function(_, callback)
      prompt_callback = callback
    end)
    quickdraw._test.set_directory_creator(function()
      return 1
    end)
    quickdraw._test.set_session_starter(function()
      return { browser_opened = true }, nil
    end)

    vim.cmd("Quickdraw")
    prompt_callback("diagram")
    assert.are.equal(0, #notifications)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "![](diagram.png)" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    vim.cmd("Quickdraw")
    assert.are.equal(0, #notifications)
  end)

  it("warns with the exact browser URL while keeping the successful result", function()
    source_plugin()
    new_buffer("markdown", "/tmp/quickdraw-command.md")
    quickdraw._test.set_input(function(_, callback)
      prompt_callback = callback
    end)
    quickdraw._test.set_directory_creator(function()
      return 1
    end)
    local url = "http://127.0.0.1:4321/unrelated-token/"
    local info = {
      url = url,
      browser_opened = false,
      warning = { code = "BROWSER_OPEN_FAILED", message = "default browser could not be opened" },
    }
    local started
    quickdraw._test.set_session_starter(function()
      started = info
      return info, nil
    end)

    vim.cmd("Quickdraw")
    prompt_callback("diagram")

    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.are.equal("quickdraw.nvim", notifications[1].options.title)
    assert.are.equal("Open this URL in your browser: " .. url, notifications[1].message)
    assert.are.equal(info, started)
    assert.is_truthy(vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]:find(url, 1, true) == nil)
  end)

  it("does not crash when the injected notifier fails", function()
    source_plugin()
    new_buffer("text", "/tmp/quickdraw-command.txt")
    quickdraw._test.set_notifier(function()
      error("notifier failed")
    end)

    local ok = pcall(vim.cmd, "Quickdraw")

    assert.is_true(ok)
  end)
end)
