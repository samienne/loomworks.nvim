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

  it("global options are accepted anywhere", function()
    assert_reached(run(root, "--no-input", "build", "Dev", "--non-interactive", "--force"), "cmd_build")
    assert_reached(run(root, "build", "--dev", "--no-pin", "Dev"), "cmd_build")
  end)

  it("lw launch add: the program's args after the command are never checked", function()
    assert_reached(run(root, "launch", "add", "App", "docs", "python", "-m", "http.server",
      "--bind", "0"), "cmd_launch")
    assert_reached(run(root, "launch", "add", "App", "demo", "--from-target", "editor",
      "--theme", "demo"), "cmd_launch")
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
end)
