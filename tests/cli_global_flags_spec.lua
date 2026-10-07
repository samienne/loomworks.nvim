-- Global options (spec §16.7) are lw's own options: recognised before the
-- command and among the command's own arguments — never after `--` and never
-- inside a program's arguments (a launch configuration's args after its
-- command / target, `lw launch set`'s argument list). Regression for a report
-- where `lw --no-input launch set App demo --dev --x` (and the `-- --dev` and
-- `launch add … Editor.exe -- --dev` forms) were read as the global `--dev`
-- (development source) instead of being stored as program arguments.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local t = assert(io.open(root .. "/App/tsconfig.json", "w")); t:write("{}"); t:close()
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  return root
end

local HANDLERS = { "cmd_run", "cmd_build", "cmd_test", "cmd_launch", "cmd_configuration" }

--- Drive the real dispatcher with the handlers stubbed; return the argv the
--- handler received (the args table is the handler's last argument).
local function dispatch(root, ...)
  local argv = { ... }
  local saved, called = {}, {}
  for _, nm in ipairs(HANDLERS) do
    saved[nm] = cli[nm]
    cli[nm] = function(...)
      local p = { ... }
      called.name = nm
      for _, v in ipairs(p) do if type(v) == "table" and v[1] then called.args = v end end
      return 0
    end
  end
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg, vim.env.LW_ROOT = argv, root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  for _, nm in ipairs(HANDLERS) do cli[nm] = saved[nm] end
  r.called, r.args = called.name, called.args
  return r
end

local function has(list, v)
  for _, x in ipairs(list or {}) do if x == v then return true end end
  return false
end

describe("global options stop at the command's program arguments", function()
  local root = make_root()

  it("launch set: a trailing --dev is a program argument", function()
    local r = dispatch(root, "--no-input", "launch", "set", "App", "demo",
      "--dev", "--use-scene-json-schema", "D:\\src\\x")
    assert.equals(0, r.exit_code, r.stderr)
    assert.equals("cmd_launch", r.called)
    assert.is_true(has(r.args, "--dev"), vim.inspect(r.args))
  end)

  it("launch set: --dev after -- is a program argument", function()
    local r = dispatch(root, "--no-input", "launch", "set", "App", "demo",
      "--", "--dev", "--use-scene-json-schema", "D:\\src\\x")
    assert.equals("cmd_launch", r.called, r.stderr)
    assert.is_true(has(r.args, "--dev"), vim.inspect(r.args))
  end)

  it("launch add: --dev after -- is a program argument", function()
    local r = dispatch(root, "--no-input", "launch", "add", "App", "editor-dev", "Editor.exe", "--", "--dev")
    assert.equals("cmd_launch", r.called, r.stderr)
    assert.is_true(has(r.args, "--dev"), vim.inspect(r.args))
  end)

  it("launch add: options after the command operand are the program's", function()
    local r = dispatch(root, "launch", "add", "App", "editor-dev", "Editor.exe", "--dev", "--no-input")
    assert.equals("cmd_launch", r.called, r.stderr)
    assert.is_true(has(r.args, "--dev") and has(r.args, "--no-input"), vim.inspect(r.args))
  end)

  it("run / test / build: global options after -- are passed through", function()
    local r = dispatch(root, "run", "demo", "--", "--dev", "--no-input", "--no-pin", "--local")
    assert.equals("cmd_run", r.called, r.stderr)
    for _, v in ipairs({ "--dev", "--no-input", "--no-pin", "--local" }) do
      assert.is_true(has(r.args, v), v .. " " .. vim.inspect(r.args))
    end
    r = dispatch(root, "test", "Dev", "--", "--shared", "--no-daemon")
    assert.equals("cmd_test", r.called, r.stderr)
    assert.is_true(has(r.args, "--shared") and has(r.args, "--no-daemon"), vim.inspect(r.args))
    r = dispatch(root, "build", "Dev", "--", "--dev=x")
    assert.equals("cmd_build", r.called, r.stderr)
    assert.is_true(has(r.args, "--dev=x"), vim.inspect(r.args))
  end)

  it("a set-value operand that spells a global option is the value", function()
    local r = dispatch(root, "config", "set", "App", "Debug", "options.X", "--local")
    assert.equals("cmd_configuration", r.called, r.stderr)
    assert.is_true(has(r.args, "--local"), vim.inspect(r.args))
  end)

  it("global options among a command's own arguments are still recognised", function()
    local r = dispatch(root, "build", "--dev", "--no-pin", "Dev", "--no-input")
    assert.equals("cmd_build", r.called, r.stderr)
    assert.is_false(has(r.args, "--dev") or has(r.args, "--no-pin") or has(r.args, "--no-input"),
      vim.inspect(r.args))
    r = dispatch(root, "run", "demo", "--no-input", "--", "x")
    assert.equals("cmd_run", r.called, r.stderr)
    assert.is_false(has(r.args, "--no-input"), vim.inspect(r.args))
    r = dispatch(root, "launch", "add", "App", "n", "--no-input", "node", "-x")
    assert.equals("cmd_launch", r.called, r.stderr)
    assert.is_false(has(r.args, "--no-input"), vim.inspect(r.args))
  end)
end)

describe("launch add / set take the args after --", function()
  local function make_ws()
    local root = make_root()
    capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
    return root
  end
  local function launch(root, ...)
    local args = { "launch", ... }
    return capture(function() return cli.cmd_launch(args[2], root, args) end)
  end
  local function cfg(root, name)
    local ws = assert(cli._load_workspace(root, false))
    for _, p in pairs(ws._projects) do
      if p.key == "App" then return p.launch and p.launch[name] end
    end
  end

  it("launch add <cmd> -- args stores the args without the --", function()
    local root = make_ws()
    local r = launch(root, "add", "App", "editor-dev", "Editor.exe", "--", "--dev", "--env", "X")
    assert.is_nil(r.exit_code, r.stderr)
    local c = cfg(root, "editor-dev")
    assert.equals("Editor.exe", c.command)
    assert.same({ "--dev", "--env", "X" }, c.args)
  end)

  it("launch set -- args replaces the args verbatim", function()
    local root = make_ws()
    launch(root, "add", "App", "demo", "node", "a.js")
    local r = launch(root, "set", "App", "demo", "--", "--dev", "--use-scene-json-schema", "D:\\src\\x")
    assert.is_nil(r.exit_code, r.stderr)
    assert.same({ "--dev", "--use-scene-json-schema", "D:\\src\\x" }, cfg(root, "demo").args)
    r = launch(root, "set", "App", "demo", "--dev", "--working-dir", "w")
    assert.is_nil(r.exit_code, r.stderr)
    local c = cfg(root, "demo")
    assert.same({ "--dev" }, c.args)
    assert.equals("w", c.working_dir)
  end)
end)
