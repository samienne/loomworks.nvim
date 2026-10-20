-- Unknown options are usage errors (spec §16.7, "Unknown options"). Before
-- v0.1.40-beta.2 every command silently ignored an option it did not know
-- (`lw run <profile> <name> --dryrun` built and ran the program). Now an
-- unknown option before `--` exits 2, names the option and points at
-- `lw help <command>`, and nothing runs. Everything after `--` — and, for
-- `lw launch add`, everything after the command operand — belongs to the
-- program / native tool and is never checked.

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

--- Drive the real dispatcher with every command handler stubbed, recording
--- which handler was reached and with which argv. The unknown-option check
--- must refuse BEFORE any handler (so before any build) runs.
local HANDLERS = {
  "cmd_run", "cmd_build", "cmd_test", "cmd_clean", "cmd_launch", "cmd_configuration",
  "cmd_profile", "cmd_project", "cmd_cset", "cmd_status", "cmd_health", "cmd_target",
  "cmd_device", "cmd_tools", "cmd_unlock", "cmd_settings", "cmd_sdk", "cmd_trust",
}
local function run(root, ...)
  local argv = { ... }
  local saved, called = {}, {}
  for _, nm in ipairs(HANDLERS) do
    saved[nm] = cli[nm]
    cli[nm] = function(...) called.name = nm; called.args = { ... }; return 0 end
  end
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg, vim.env.LW_ROOT = argv, root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  for _, nm in ipairs(HANDLERS) do cli[nm] = saved[nm] end
  r.called = called.name
  r.args = called.args
  return r
end

local function assert_refused(r, opt, cmd)
  assert.equals(2, r.exit_code, r.stderr)
  assert.is_nil(r.called, "reached " .. tostring(r.called))
  assert.is_truthy(r.stderr:find("unknown option '" .. opt .. "'", 1, true), r.stderr)
  assert.is_truthy(r.stderr:find("lw help " .. cmd, 1, true), r.stderr)
end

local function assert_reached(r, handler)
  assert.equals(0, r.exit_code, r.stderr)
  assert.equals(handler, r.called)
end

describe("unknown options", function()
  local root = make_root()

  it("lw run <profile> <name> --dryrun is refused before any build", function()
    assert_refused(run(root, "run", "Dev", "demo", "--dryrun"), "--dryrun", "run")
    assert_refused(run(root, "run", "--bogus"), "--bogus", "run")
  end)

  it("lw run keeps its own options and forwards everything after --", function()
    assert_reached(run(root, "run", "Dev", "demo", "--dry-run"), "cmd_run")
    assert_reached(run(root, "run", "Dev", "demo", "--print=json", "--no-build"), "cmd_run")
    assert_reached(run(root, "run", "demo", "--prefix", "valgrind --leak-check=full"), "cmd_run")
    assert_reached(run(root, "run", "demo", "--project", "App", "--launch", "--cwd", "x"), "cmd_run")
    assert_reached(run(root, "run", "demo", "--device", "S1", "--fresh", "--timeout", "5",
      "--log", "a=b", "--no-wait"), "cmd_run")
    local r = run(root, "run", "demo", "--", "--dryrun", "-x")
    assert_reached(r, "cmd_run")
  end)

  it("lw build / lw test: strict before --, untouched after", function()
    assert_refused(run(root, "build", "--bogus"), "--bogus", "build")
    assert_reached(run(root, "build", "Dev", "--force", "--reconfigure", "-v", "--target", "a",
      "--target=b", "--", "--bogus", "-j4"), "cmd_build")
    assert_refused(run(root, "test", "Dev", "--gtest_filter=x"), "--gtest_filter=x", "test")
    assert_reached(run(root, "test", "Dev", "--junit", "o.xml", "--target", "t",
      "--", "--gtest_filter=x"), "cmd_test")
  end)

  -- Every option cmd_test parses must be in lw test's known-option table:
  -- the unit tests call cmd_test directly, so a gap only shows on the real
  -- command line (`lw test --no-build` was refused as unknown, spec §16.16).
  it("lw test accepts every option its parser handles", function()
    assert_reached(run(root, "test", "Dev", "--no-build"), "cmd_test")
    assert_reached(run(root, "test", "--no-build", "--saved", "--junit", "o.xml"), "cmd_test")
    assert_reached(run(root, "test", "--discovered", "--no-build"), "cmd_test")
    assert_reached(run(root, "test", "Dev", "--list", "--json"), "cmd_test")
    assert_reached(run(root, "test", "Dev", "--target", "t", "--cwd", "d", "--no-build"), "cmd_test")
    assert_reached(run(root, "test", "--target", "t", "--working-dir", "d"), "cmd_test")
    assert_reached(run(root, "test", "Dev", "--device", "S1", "--fresh", "--no-wait", "--timeout", "5",
      "--query-timeout", "5", "--transfer-timeout", "5", "--log", "a=b"), "cmd_test")
    assert_reached(run(root, "test", "Dev", "--no-build", "--", "--no-build", "--bogus"), "cmd_test")
  end)

  it("global options are accepted anywhere", function()
    assert_reached(run(root, "--no-input", "build", "Dev", "--non-interactive", "--force"), "cmd_build")
    assert_reached(run(root, "build", "--dev", "--no-pin", "Dev"), "cmd_build")
  end)

  it("lw launch add: the program's args after the command are never checked", function()
    assert_reached(run(root, "launch", "add", "App", "docs", "python", "-m", "http.server",
      "--bind", "0"), "cmd_launch")
    -- A target-backed add has no command token: its program args follow `--`.
    assert_reached(run(root, "launch", "add", "App", "demo", "--from-target", "editor",
      "--", "--theme", "demo"), "cmd_launch")
    assert_refused(run(root, "launch", "add", "App", "demo", "--from-target", "editor",
      "--theme", "demo"), "--theme", "launch add")
    -- `launch set`: an unknown option before `--` is refused (not taken as args).
    assert_refused(run(root, "launch", "set", "App", "demo", "--theme", "x"), "--theme", "launch set")
    assert_reached(run(root, "launch", "set", "App", "demo", "--", "--description", "x"), "cmd_launch")
    assert_reached(run(root, "launch", "add", "App", "demo", "--env", "A=1", "node", "-x"), "cmd_launch")
    assert_refused(run(root, "launch", "add", "App", "demo", "--bogus", "node"), "--bogus", "launch add")
    assert_reached(run(root, "launch", "add", "App", "demo", "--description", "d", "node"), "cmd_launch")
    assert_reached(run(root, "launch", "show", "App", "demo", "--json"), "cmd_launch")
    assert_reached(run(root, "launch", "describe", "--project", "App", "--launch", "demo",
      "-m", "x"), "cmd_launch")
    assert_reached(run(root, "launch", "rename", "App", "a", "b"), "cmd_launch")
    assert_refused(run(root, "launch", "rename", "App", "a", "b", "--force"), "--force", "launch rename")
  end)

  it("a value operand may start with '-' (config set / profile set / project set)", function()
    assert_reached(run(root, "config", "set", "App", "Debug", "options.X", "-O2"), "cmd_configuration")
    assert_reached(run(root, "profile", "set", "Dev", "App", "V", "-x"), "cmd_profile")
    assert_reached(run(root, "project", "set", "App", "V", "-x", "--type", "string"), "cmd_project")
    assert_refused(run(root, "config", "show", "App", "Debug", "--json"), "--json", "config show")
  end)

  it("sub-commands and simple commands refuse unknown options", function()
    assert_refused(run(root, "profile", "list", "--json"), "--json", "profile list")
    assert_refused(run(root, "status", "--bogus"), "--bogus", "status")
    assert_reached(run(root, "status", "--check", "--cache-stats"), "cmd_status")
    assert_refused(run(root, "clean", "--all"), "--all", "clean")
    assert_refused(run(root, "target", "set", "Dev", "x", "--bogus"), "--bogus", "target set")
    assert_reached(run(root, "target", "set", "Dev", "x", "--launch", "--cwd", "d"), "cmd_target")
    assert_refused(run(root, "tools", "--json"), "--json", "tools")
    assert_reached(run(root, "health", "--json", "-v", "--force", "--all"), "cmd_health")
  end)

  it("create verbs keep -m; describe keeps its sources", function()
    assert_reached(run(root, "profile", "create", "Dev", "-m", "para", "--activate"), "cmd_profile")
    assert_reached(run(root, "project", "describe", "App", "-m", "x", "-m=y"), "cmd_project")
    assert_reached(run(root, "project", "describe", "App", "-F", "-"), "cmd_project")
    assert_refused(run(root, "profile", "create", "Dev", "--bogus"), "--bogus", "profile create")
  end)

  -- Option values (spec §16.7 "Option values"), on every command through the
  -- shared parser: `--opt=value` reaches the handler split, a missing value or
  -- a single-valued option given twice is a usage error (exit 2) before any
  -- handler runs.
  local function args_of(r)
    return r.called and r.args[#r.args] or nil
  end
  local function has_seq(list, a, b)
    for i = 1, #(list or {}) - 1 do if list[i] == a and list[i + 1] == b then return true end end
    return false
  end
  local function assert_usage(r, needle)
    assert.equals(2, r.exit_code, r.stderr)
    assert.is_nil(r.called, "reached " .. tostring(r.called))
    assert.is_truthy(r.stderr:find(needle, 1, true), r.stderr)
  end

  it("--opt=value is split for valued options on run / test / target set", function()
    local r = run(root, "run", "Dev", "demo", "--cwd=w", "--prefix=valgrind -q")
    assert_reached(r, "cmd_run")
    local a = args_of(r)
    assert.is_true(has_seq(a, "--cwd", "w"), vim.inspect(a))
    assert.is_true(has_seq(a, "--prefix", "valgrind -q"), vim.inspect(a))
    r = run(root, "test", "Dev", "--target", "t", "--working-dir=--d")
    assert_reached(r, "cmd_test")
    assert.is_true(has_seq(args_of(r), "--working-dir", "--d"), vim.inspect(args_of(r)))
    r = run(root, "target", "set", "Dev", "x", "--launch", "--working-dir=d")
    assert_reached(r, "cmd_target")
    assert.is_true(has_seq(args_of(r), "--working-dir", "d"), vim.inspect(args_of(r)))
    -- After `--` nothing is split.
    r = run(root, "run", "Dev", "demo", "--", "--cwd=w")
    assert_reached(r, "cmd_run")
    assert.is_false(has_seq(args_of(r), "--cwd", "w"), vim.inspect(args_of(r)))
  end)

  it("a single-valued option given twice is a usage error", function()
    assert_usage(run(root, "run", "Dev", "demo", "--cwd", "a", "--cwd", "b"), "--cwd")
    assert_usage(run(root, "run", "Dev", "demo", "--cwd", "a", "--working-dir=b"), "--working-dir")
    assert_usage(run(root, "test", "Dev", "--target", "t", "--working-dir", "a", "--cwd", "b"), "--cwd")
    assert_usage(run(root, "target", "set", "Dev", "x", "--working-dir", "a", "--working-dir", "b"),
      "--working-dir")
    -- Repeatable ones may repeat.
    assert_reached(run(root, "test", "Dev", "--target", "a", "--target=b", "--log", "a=1", "--log", "b=2"),
      "cmd_test")
    assert_reached(run(root, "build", "Dev", "--target", "a", "--target=b"), "cmd_build")
  end)

  it("a missing value is a usage error", function()
    assert_usage(run(root, "run", "Dev", "demo", "--cwd"), "--cwd")
    assert_usage(run(root, "run", "Dev", "demo", "--cwd", "--", "x"), "--cwd")
    assert_usage(run(root, "test", "Dev", "--junit", "--no-build"), "--junit")
    assert_usage(run(root, "target", "set", "Dev", "x", "--working-dir", "--no-input"), "--working-dir")
    -- A value with one leading dash is a value.
    assert_reached(run(root, "test", "Dev", "--target", "t", "--cwd", "-d"), "cmd_test")
  end)
end)
