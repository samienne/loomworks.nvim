-- `lw <project|config|configset|profile> describe` and the description
-- display rules of spec §16.35: read / write / clear forms, the text sources
-- (-m, -F, stdin, -e), --json, --no-input, the `config set … description`
-- alias, `-m` on create verbs, summaries in list/status rows and full text in
-- show views, and inert rendering of untrusted description text (§17.11).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
  return {
    exit_code = exit_code,
    ret = ok and ret or nil,
    stdout = table.concat(out_buf),
    stderr = table.concat(err_buf),
  }
end

--- Temp workspace: typescript App with a user `Debug` config, a `Dev` set
--- (App=Debug) and a `Dev` profile.
local function make_ws(extra_lw)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = extra_lw or { projects = { App = { typescript = vim.empty_dict() } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

local function read_user(root)
  local f = io.open(root .. "/.nvim/loomworks.user.json", "r")
  if not f then return nil end
  local c = f:read("*a"); f:close()
  return vim.json.decode(c)
end

local function describe_cmd(root, kind, ...)
  local argv = { kind, "describe", ... }
  return capture(function()
    if kind == "project" then return cli.cmd_project("describe", root, argv[3], argv[4], argv[5], argv) end
    if kind == "config" then return cli.cmd_configuration("describe", root, argv[3], argv[4], argv[5], argv[6], argv) end
    if kind == "configset" then return cli.cmd_cset("describe", root, argv) end
    return cli.cmd_profile("describe", root, argv)
  end)
end

local function profile_key(root)
  return read_user(root).active_profile
end

describe("lw describe", function()
  before_each(function()
    cli._test_interactive = false
    cli._test_stdout_tty = false
    cli._describe_read_stdin = nil
    cli._describe_run_editor = nil
    cli._create_paras = nil
  end)
  after_each(function()
    cli._test_interactive = nil
    cli._test_stdout_tty = nil
    cli._describe_read_stdin = nil
    cli._describe_run_editor = nil
  end)

  it("sets a project description with -m paragraphs, reads it back, clears it", function()
    local root = make_ws()
    local r = describe_cmd(root, "project", "App", "-m", "Core app", "-m", "Body line.")
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("project 'App' described", 1, true))
    -- Stored inside the module section (spec §1.10), normalised.
    local u = read_user(root)
    assert.equals("Core app\n\nBody line.", u.projects.App.typescript.description)
    assert.is_nil(u.projects.App.description)

    local g = describe_cmd(root, "project", "App")
    assert.equals("Core app\n\nBody line.\n", g.stdout)

    local j = describe_cmd(root, "project", "App", "--json")
    local obj = vim.json.decode(j.stdout)
    assert.equals("project", obj.kind)
    assert.equals("App", obj.name)
    assert.equals("Core app", obj.summary)
    assert.equals("Core app\n\nBody line.", obj.description)
    assert.equals("workspace", obj.source)

    local c = describe_cmd(root, "project", "App", "--clear")
    assert.is_truthy(c.stdout:find("description removed", 1, true))
    assert.is_nil(read_user(root).projects.App.typescript.description)
    -- Clearing again changes nothing.
    local c2 = describe_cmd(root, "project", "App", "--clear")
    assert.is_nil(c2.exit_code)
    assert.is_truthy(c2.stdout:find("has no description", 1, true))
  end)

  it("an empty text removes the key (never stored as \"\"); unchanged writes nothing", function()
    local root = make_ws()
    describe_cmd(root, "configset", "Dev", "What CI ships  \r\n")
    local u = read_user(root)
    assert.equals("What CI ships", u.configuration_set_descriptions.Dev)
    local same = describe_cmd(root, "configset", "Dev", "What CI ships")
    assert.is_truthy(same.stdout:find("(unchanged)", 1, true))
    describe_cmd(root, "configset", "Dev", "")
    assert.is_nil(read_user(root).configuration_set_descriptions)
  end)

  it("describes a user configuration; config set/unset/get description are aliases", function()
    local root = make_ws()
    local r = capture(function() cli.cmd_configuration("set", root, "App", "Debug", "description", "Debug build") end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.equals("Debug build", read_user(root).projects.App.typescript.configurations.Debug.description)
    local g = capture(function() cli.cmd_configuration("get", root, "App", "Debug", "description") end)
    assert.equals("Debug build\n", g.stdout)
    -- `config show` shows it under `description`, not among module fields.
    local s = capture(function() cli.cmd_configuration("show", root, "App", "Debug") end)
    assert.is_truthy(s.stdout:find("  description     Debug build", 1, true))
    assert.is_nil(s.stdout:find("module fields", 1, true))
    capture(function() cli.cmd_configuration("unset", root, "App", "Debug", "description") end)
    assert.is_nil(read_user(root).projects.App.typescript.configurations.Debug.description)
  end)

  it("refuses to describe a generated configuration", function()
    local root = make_ws()
    local r = describe_cmd(root, "config", "App", "variant:default", "nope")
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("lw config add App", 1, true))
    -- Reading a generated configuration without a default is fine.
    local g = describe_cmd(root, "config", "App", "variant:default")
    assert.is_nil(g.exit_code)
    assert.equals("", g.stdout)
  end)

  it("profile describe requires the profile and resolves numbers", function()
    local root = make_ws()
    local r = describe_cmd(root, "profile")
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("usage: lw profile describe", 1, true))
    local ok = describe_cmd(root, "profile", "1", "-m", "Personal build")
    assert.is_nil(ok.exit_code, ok.stderr)
    local key = profile_key(root)
    assert.equals("Personal build", read_user(root).profiles[key].description)
  end)

  it("reads the text from stdin (- and -F -) and from a file", function()
    local root = make_ws()
    cli._describe_read_stdin = function() return "From stdin\n\nbody\n" end
    describe_cmd(root, "project", "App", "-")
    assert.equals("From stdin\n\nbody", read_user(root).projects.App.typescript.description)
    cli._describe_read_stdin = function() return "Again\n" end
    describe_cmd(root, "project", "App", "-F", "-")
    assert.equals("Again", read_user(root).projects.App.typescript.description)
    local path = vim.fn.tempname()
    local f = assert(io.open(path, "wb")); f:write("From file\r\n"); f:close()
    describe_cmd(root, "project", "App", "-F", path)
    assert.equals("From file", read_user(root).projects.App.typescript.description)
  end)

  it("usage errors: two sources, --clear with text, --json with text", function()
    local root = make_ws()
    assert.equals(1, describe_cmd(root, "project", "App", "x", "-m", "y").exit_code)
    assert.equals(1, describe_cmd(root, "project", "App", "x", "--clear").exit_code)
    assert.equals(1, describe_cmd(root, "project", "App", "x", "--json").exit_code)
    assert.equals(1, describe_cmd(root, "project", "App", "--bogus").exit_code)
  end)

  it("refuses control characters and oversize text", function()
    local root = make_ws()
    local r = describe_cmd(root, "project", "App", "bad\27[31m")
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("control character", 1, true))
    local big = describe_cmd(root, "project", "App", string.rep("x", 5000))
    assert.equals(1, big.exit_code)
    assert.is_nil(read_user(root).projects.App.typescript.description)
  end)

  it("-e is refused non-interactively, naming the scriptable forms", function()
    local root = make_ws()
    local r = describe_cmd(root, "project", "App", "-e")
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("-m", 1, true))
  end)

  it("-e opens $VISUAL, drops # lines, saving empty removes, a failing editor aborts", function()
    local root = make_ws()
    cli._test_interactive = true
    local saved_visual = vim.env.VISUAL
    vim.env.VISUAL = "fake-editor --wait"
    local seen
    cli._describe_run_editor = function(step)
      seen = step.cmd
      local path = step.cmd[#step.cmd]
      local f = assert(io.open(path, "rb")); local pre = f:read("*a"); f:close()
      assert.is_truthy(pre:find("# Describe project 'App'", 1, true))
      f = assert(io.open(path, "wb"))
      f:write("Edited summary\n\nEdited body\n# a comment\n"); f:close()
      return 0
    end
    describe_cmd(root, "project", "App", "-e")
    assert.same({ "fake-editor", "--wait" }, { seen[1], seen[2] })
    assert.equals("Edited summary\n\nEdited body", read_user(root).projects.App.typescript.description)

    cli._describe_run_editor = function() return 1 end
    local ab = describe_cmd(root, "project", "App", "-e")
    assert.is_nil(ab.exit_code)
    assert.equals("Edited summary\n\nEdited body", read_user(root).projects.App.typescript.description)

    cli._describe_run_editor = function(step)
      local f = assert(io.open(step.cmd[#step.cmd], "wb")); f:write("# only comments\n"); f:close()
      return 0
    end
    describe_cmd(root, "project", "App", "-e")
    assert.is_nil(read_user(root).projects.App.typescript.description)
    vim.env.VISUAL = saved_visual
  end)

  it("-m on a create verb describes the new item", function()
    local root = make_ws()
    local argv = { "configset", "create", "Rel", "App=Debug", "-m", "Release set" }
    cli._extract_create_paras(argv)
    assert.same({ "configset", "create", "Rel", "App=Debug" }, argv)
    capture(function() cli.cmd_cset("create", root, argv) end)
    assert.equals("Release set", read_user(root).configuration_set_descriptions.Rel)
  end)

  it("shows summaries in list rows (fitted, 60 max off a terminal) and full text in show", function()
    local root = make_ws()
    local long = "A very long summary line that certainly exceeds the sixty column cap for lists"
    describe_cmd(root, "project", "App", "-m", long, "-m", "Body text")
    local l = capture(function() cli.cmd_project("list", root) end)
    local expect = require("loomworks.description").fit(long, 60)
    assert.is_truthy(l.stdout:find("  " .. expect, 1, true))
    assert.is_nil(l.stdout:find("Body text", 1, true))
    local s = capture(function() cli.cmd_project("show", root, "App") end)
    assert.is_truthy(s.stdout:find("  description     " .. long, 1, true))
    assert.is_truthy(s.stdout:find("                  Body text", 1, true))

    describe_cmd(root, "configset", "Dev", "Set summary")
    local cl = capture(function() cli.cmd_cset("list", root, { "configset", "list" }) end)
    -- One layout rule (§16.35): name, summary column, then the mappings.
    assert.is_truthy(cl.stdout:find("  Dev               Set summary  App→Debug", 1, true))
  end)

  it("configset list: summary column aligned, blank for undescribed sets, capped at 36", function()
    local root = make_ws()
    capture(function() cli.cmd_cset("create", root, { "configset", "create", "Bare", "App=Debug" }) end)
    describe_cmd(root, "configset", "Dev", string.rep("s", 50))
    local out = capture(function() cli.cmd_cset("list", root, { "configset", "list" }) end).stdout
    local lines = vim.split(out, "\n", { plain = true })
    -- Both mapping lists start in the same column.
    local function col(l) return vim.fn.strdisplaywidth(l:sub(1, l:find("App→Debug", 1, true) - 1)) end
    assert.equals(col(lines[1]), col(lines[2]))
    assert.is_truthy(lines[2]:find(string.rep("s", 35) .. "…", 1, true))
    assert.is_nil(out:find("\n      ", 1, true)) -- no continuation lines
  end)

  it("configset list on a terminal cuts the mappings, not the summary", function()
    local root = make_ws()
    describe_cmd(root, "configset", "Dev", "Set summary")
    cli._test_stdout_tty = true
    local saved = cli._term_width
    cli._term_width = function() return 58 end
    local out = capture(function() cli.cmd_cset("list", root, { "configset", "list" }) end).stdout
    cli._term_width = saved
    for _, l in ipairs(vim.split(out, "\n", { plain = true, trimempty = true })) do
      assert.is_true(vim.fn.strdisplaywidth(l) <= 58, l)
    end
    assert.is_truthy(out:find("Set summary  App", 1, true), out)
    -- The mappings take the truncation when the terminal is tight.
    local row = cli._row_with_summary("  Dev", "Set summary", 11,
      { "App→Debug", "Lib→Release", "Tools→Debug" }, 16)
    assert.is_truthy(row:find("Set summary  App→Debug …+2", 1, true), row)
  end)

  it("configset list on a narrow terminal moves summaries to continuation lines", function()
    local root = make_ws()
    describe_cmd(root, "configset", "Dev", "Set summary")
    cli._test_stdout_tty = true
    local saved = cli._term_width
    cli._term_width = function() return 40 end
    local out = capture(function() cli.cmd_cset("list", root, { "configset", "list" }) end).stdout
    cli._term_width = saved
    assert.is_truthy(out:find("App→Debug\n      Set summary", 1, true))
  end)

  it("project list on a terminal fits the inline summary to the width", function()
    local root = make_ws()
    describe_cmd(root, "project", "App", string.rep("p", 80))
    cli._test_stdout_tty = true
    local saved = cli._term_width
    cli._term_width = function() return 70 end
    local out = capture(function() cli.cmd_project("list", root) end).stdout
    cli._term_width = saved
    local line = vim.split(out, "\n", { plain = true })[1]
    assert.is_truthy(line:find("…", 1, true))
    assert.is_true(vim.fn.strdisplaywidth(line) <= 70)
  end)

  it("lw status: the summary comes before the open-ended list in set and project rows", function()
    local root = make_ws()
    describe_cmd(root, "configset", "Dev", "Set summary")
    describe_cmd(root, "project", "App", "Project summary")
    local saved = vim.env.COLUMNS
    vim.env.COLUMNS = "100"
    local out = capture(function() return cli.cmd_status(root, {}) end).stdout
    vim.env.COLUMNS = saved
    local set_line = out:match("\n(  Dev[^\n]*)")
    assert.is_truthy(set_line)
    assert.is_true(set_line:find("Set summary", 1, true) < set_line:find("App→Debug", 1, true))
    local proj_line = out:match("\n(  App +typescript[^\n]*)")
    assert.is_truthy(proj_line)
    assert.is_true(proj_line:find("Project summary", 1, true) < proj_line:find("Debug", 1, true))
  end)

  it("lw status cuts project and set lists at whole names at 60/80/100/140 columns", function()
    local root = make_ws()
    for _, c in ipairs({ "OhosRelease", "Release", "RelWithDebInfo" }) do
      capture(function() cli.cmd_configuration("add", root, "App", c) end)
    end
    capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Ohos", "App=OhosRelease" }) end)
    describe_cmd(root, "project", "App", "App plugin: scene API, import pipeline and ECS glue")
    describe_cmd(root, "configset", "Dev", "Development builds of every project in the tree")
    local cfgs = { Debug = 1, OhosRelease = 1, RelWithDebInfo = 1, Release = 1 }
    local saved = vim.env.COLUMNS
    cli._test_stdout_tty = true
    for _, w in ipairs({ 60, 80, 100, 140 }) do
      vim.env.COLUMNS = tostring(w)
      local out = capture(function() return cli.cmd_status(root, {}) end).stdout
      local proj_line = out:match("\n(  App +typescript[^\n]*)")
      assert.is_truthy(proj_line, out)
      -- The configuration list is the text after the summary column.
      local at = proj_line:find("Debug", 1, true)
      assert.is_truthy(at, w .. " cols: " .. proj_line)
      local list = proj_line:sub(at)
      list = list:gsub(" …%+%d+$", ""):gsub(" %+%d+$", "")
      for entry in (list .. ", "):gmatch("(.-), ") do
        assert.is_truthy(cfgs[entry], w .. " cols: cut entry '" .. entry .. "' in: " .. proj_line)
      end
      local set_line = out:match("\n(  Dev [^\n]*)")
      assert.is_truthy(set_line:find("App→Debug", 1, true), set_line)
    end
    vim.env.COLUMNS = saved
  end)

  it("lw status shows each item's summary", function()
    local root = make_ws()
    describe_cmd(root, "configset", "Dev", "Set summary")
    describe_cmd(root, "project", "App", "Project summary")
    describe_cmd(root, "profile", "1", "Profile summary")
    local r = capture(function() return cli.cmd_status(root, {}) end)
    assert.is_truthy(r.stdout:find("Set summary", 1, true))
    assert.is_truthy(r.stdout:find("Project summary", 1, true))
    assert.is_truthy(r.stdout:find("Profile summary", 1, true))
  end)

  it("renders untrusted description text from loomworks.json inert", function()
    local evil = "Evil\27]0;pwned\7 \226\128\174txt\nbody\27[2J"
    local root = make_ws({
      projects = { App = { typescript = { description = evil } } },
    })
    local l = capture(function() cli.cmd_project("list", root) end)
    assert.is_nil(l.stdout:find("\27", 1, true))
    assert.is_nil(l.stdout:find("\226\128\174", 1, true))
    assert.is_truthy(l.stdout:find("^[]0;pwned^G", 1, true))
    assert.is_truthy(l.stdout:find("\\u202E", 1, true))
    assert.is_nil(l.stdout:find("body", 1, true)) -- summary only in a row
    local s = capture(function() cli.cmd_project("show", root, "App") end)
    assert.is_nil(s.stdout:find("\27", 1, true))
    assert.is_truthy(s.stdout:find("body^[[2J", 1, true))
  end)
end)
