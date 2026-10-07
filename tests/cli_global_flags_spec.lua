-- Global options (spec §16.7) are lw's own options: recognised before the
-- command and among the command's own arguments — never after `--` and never
-- inside a program's arguments (a launch configuration's args after its
-- command / target). On `lw launch set` and the set-value commands `--` is the
-- escape. Regression for a report where `lw launch set App demo -- --dev`,
-- `launch add … Editor.exe -- --dev` and `run demo -- --dev` were read as the
-- global `--dev` (development source) instead of being program arguments.

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

local HANDLERS = { "cmd_run", "cmd_build", "cmd_test", "cmd_launch", "cmd_configuration",
  "cmd_project" }

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

  it("launch set: a --dev before -- is lw's own (the host hints to use --)", function()
    local r = dispatch(root, "--no-input", "launch", "set", "App", "demo",
      "--dev", "--use-scene-json-schema", "D:\\src\\x")
    assert.equals(0, r.exit_code, r.stderr)
    assert.equals("cmd_launch", r.called)
    assert.is_false(has(r.args, "--dev"), vim.inspect(r.args))
    local pin = require("boot.pin")
    local _, f = pin.peel_host_flags({ "launch", "set", "App", "demo", "--dev" })
    assert.is_true(f.dev and f.dev_in_args)
    assert.truthy(pin.dev_unconfigured_message(f.dev_in_args):find("put it after `--`", 1, true))
  end)

  it("launch set / set-value commands: a trailing global option is lw's own", function()
    local r = dispatch(root, "launch", "set", "app", "run", "--env", "K=V", "--no-input")
    assert.equals("cmd_launch", r.called, r.stderr)
    assert.same({ "launch", "set", "app", "run", "--env", "K=V" }, r.args)
    r = dispatch(root, "project", "set", "App", "V", "x", "--no-input")
    assert.equals("cmd_project", r.called, r.stderr)
    assert.same({ "project", "set", "App", "V", "x" }, r.args)
  end)

  it("a program's --help is an argument, not a help request", function()
    local r = dispatch(root, "launch", "add", "app", "x", "node", "--help")
    assert.equals("cmd_launch", r.called, r.stdout)
    assert.is_true(has(r.args, "--help"), vim.inspect(r.args))
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
    r = dispatch(root, "test", "Dev", "--", "--shared", "--non-interactive")
    assert.equals("cmd_test", r.called, r.stderr)
    assert.is_true(has(r.args, "--shared") and has(r.args, "--non-interactive"), vim.inspect(r.args))
    r = dispatch(root, "build", "Dev", "--", "--dev=x")
    assert.equals("cmd_build", r.called, r.stderr)
    assert.is_true(has(r.args, "--dev=x"), vim.inspect(r.args))
  end)

  it("a set-value operand that spells a global option is the value after --", function()
    local r = dispatch(root, "config", "set", "App", "Debug", "options.X", "--", "--local")
    assert.equals("cmd_configuration", r.called, r.stderr)
    assert.is_true(has(r.args, "--local"), vim.inspect(r.args))
    r = dispatch(root, "config", "set", "App", "Debug", "options.X", "-O2", "--local")
    assert.equals("cmd_configuration", r.called, r.stderr)
    assert.same({ "config", "set", "App", "Debug", "options.X", "-O2" }, r.args)
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

  it("launch add <cmd> -- args keeps the -- and every token after it", function()
    local root = make_ws()
    local r = launch(root, "add", "App", "editor-dev", "Editor.exe", "--", "--dev", "--env", "X")
    assert.is_nil(r.exit_code, r.stderr)
    local c = cfg(root, "editor-dev")
    assert.equals("Editor.exe", c.command)
    assert.same({ "--", "--dev", "--env", "X" }, c.args)
    r = launch(root, "add", "App", "dev", "npm", "run", "dev", "--", "--port", "3000")
    assert.is_nil(r.exit_code, r.stderr)
    assert.same({ "run", "dev", "--", "--port", "3000" }, cfg(root, "dev").args)
  end)

  it("launch add -- <cmd> args: a -- before the command only ends lw's options", function()
    local root = make_ws()
    local r = launch(root, "add", "App", "n", "--", "node", "--dev", "--env", "X")
    assert.is_nil(r.exit_code, r.stderr)
    local c = cfg(root, "n")
    assert.equals("node", c.command)
    assert.same({ "--dev", "--env", "X" }, c.args)
  end)

  it("set-value commands: -- escapes a value that spells an option", function()
    local root = make_ws()
    local r = capture(function()
      return cli.cmd_project_set(root, { "project", "set", "App", "V", "--", "--type" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    local ws = assert(cli._load_workspace(root, false))
    local found
    for _, p in pairs(ws._projects) do
      if p.key == "App" then found = p.variables and p.variables.V end
    end
    assert.equals("--type", found and found.default)
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

describe("host and bundle walkers agree", function()
  local pin = require("boot.pin")
  local opts = require("loomworks.cli_options")
  -- Where lw's own arguments end on the whole line, per the bundle: its
  -- leading global options, then `own_end` of the rest.
  local function bundle_end(raw)
    local k = 0
    while raw[k + 1] ~= nil and opts.is_global(raw[k + 1]) do k = k + 1 end
    local tail = {}
    for j = k + 1, #raw do tail[#tail + 1] = raw[j] end
    return k + opts.own_end(tail)
  end
  local CASES = {
    { "run", "demo", "--", "--dev" },
    { "--no-input", "run", "demo", "--dev", "--", "x" },
    { "build", "--dev", "Dev", "--no-pin" },
    { "launch", "add", "app", "dev", "npm", "run", "dev", "--", "--port", "3000" },
    { "launch", "add", "App", "x", "Editor.exe", "--", "--dev" },
    { "launch", "add", "App", "x", "Editor.exe", "--dev", "--no-input" },
    { "launch", "add", "App", "x", "--no-input", "node", "--help" },
    { "launch", "add", "App", "x", "--env", "K=V", "--cwd", "w", "node", "-x" },
    { "launch", "add", "App", "x", "--", "node", "--dev" },
    { "launch", "add", "App", "x", "--from-target", "t", "--dev" },
    { "launch", "create", "App", "x", "--description", "d", "node", "--dev" },
    { "launch", "set", "App", "demo", "--dev", "--x" },
    { "launch", "set", "App", "demo", "--", "--dev" },
    { "launch", "edit", "app", "run", "--env", "K=V", "--no-input" },
    { "config", "set", "App", "Debug", "options.X", "-O2", "--no-pin" },
    { "config", "set", "App", "Debug", "options.X", "--", "--dev" },
    { "project", "set", "App", "--type", "string", "V", "--", "--no-pin" },
    { "profile", "set", "P", "App", "V", "--dev" },
    { "settings", "set", "dev-lua", "--", "--x" },
    { "--dev", "status", "--help" },
    { "--", "--dev" },
    { "frobnicate", "--dev", "--", "--dev" },
  }
  for _, raw in ipairs(CASES) do
    it(table.concat(raw, " "), function()
      assert.equals(pin.own_end(raw), bundle_end(raw))
      -- The same host flags are taken on both sides.
      local fwd = pin.peel_host_flags(raw)
      local rest, globals = opts.split_globals(raw)
      local host = 0
      for _, v in ipairs(globals) do
        if v == "--dev" or v:sub(1, 6) == "--dev=" or v == "--no-pin" then host = host + 1 end
      end
      assert.equals(#raw - #fwd, host)
      assert.equals(#raw, #rest + #globals)
    end)
  end
end)
