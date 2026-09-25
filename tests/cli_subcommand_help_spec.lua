-- `lw <command> --help` / `-h` prints that command's help (exit 0) instead of
-- treating the flag as an operand (`lw build --help` used to fail with
-- "no profile matching '--help'"); args after `--` are never intercepted.
-- Also: `lw help build` / `lw help test` show a CI pattern consistent with
-- "non-interactive ignores the active profile" (explicit profile name).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  return root
end

local function run_main(argv, root)
  local saved_arg, saved_root = _G.arg, vim.env.LW_ROOT
  _G.arg = argv
  vim.env.LW_ROOT = root
  local r = capture(function() cli.main() end)
  _G.arg, vim.env.LW_ROOT = saved_arg, saved_root
  return r
end

local function help_text(topic)
  return capture(function() cli.cmd_help(topic) end).stdout
end

describe("`lw <command> --help`", function()
  local root
  before_each(function() root = make_root() end)
  after_each(function() vim.fn.delete(root, "rf") end)

  for _, cmd in ipairs({ "build", "run", "test", "clean", "reset" }) do
    it("`lw " .. cmd .. " --help` prints `lw help " .. cmd .. "`", function()
      local r = run_main({ cmd, "--help" }, root)
      assert.equals(0, r.exit_code)
      assert.equals(help_text(cmd), r.stdout)
      assert.is_nil(r.stderr:find("no profile", 1, true))
    end)
  end

  it("`-h` works too, after other operands, and for an aliased command", function()
    assert.equals(help_text("build"), run_main({ "build", "Debug", "-h" }, root).stdout)
    assert.equals(help_text("config"), run_main({ "configuration", "--help" }, root).stdout)
    assert.equals(help_text("workspace"), run_main({ "ws", "--help" }, root).stdout)
  end)

  -- The host handles these before the CLI (lua/main.lua) but leaves `--help` to
  -- this dispatcher, so it must answer for them too.
  for _, cmd in ipairs({ "self-update", "version" }) do
    it("host command `lw " .. cmd .. " --help` prints `lw help " .. cmd .. "`", function()
      local r = run_main({ cmd, "--help" }, root)
      assert.equals(0, r.exit_code)
      assert.equals(help_text(cmd), r.stdout)
    end)
  end

  -- A sub-command's `--help` shows ITS section of the parent help, not the
  -- whole parent page.
  it("`lw profile query --help` prints the query section only", function()
    local r = run_main({ "profile", "query", "--help" }, root)
    assert.equals(0, r.exit_code)
    assert.is_truthy(r.stdout:find("lw profile query <profile> <project> <field>", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("build-dir", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("interactive picker", 1, true), r.stdout) -- `select`'s text
    assert.is_truthy(r.stdout:find("lw help profile", 1, true), r.stdout)
    assert.is_true(#r.stdout < #help_text("profile"))
  end)

  it("`lw config unset --help` prints the unset entry plus the param list", function()
    local r = run_main({ "config", "unset", "--help" }, root)
    assert.equals(0, r.exit_code)
    assert.is_truthy(r.stdout:find("lw config unset <project> <name> <param>", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("Params for get/set/unset", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("rename <project> <old> <new>", 1, true), r.stdout)
    -- `lw help config unset` is the same page
    assert.equals(r.stdout, capture(function() cli.cmd_help("config", "unset") end).stdout)
  end)

  it("an unknown sub-command falls back to the parent's full help", function()
    local r = run_main({ "profile", "frob", "--help" }, root)
    assert.equals(0, r.exit_code)
    assert.equals(help_text("profile"), r.stdout)
  end)

  it("user-facing help never cites spec sections", function()
    for _, topic in ipairs({ "status", "build", "clean", "reset", "unlock", "run", "target",
      "launch", "test", "init", "workspace", "migrate", "cache", "health", "module", "publish",
      "pull", "worktree", "project", "config", "configset", "profile", "settings", "completion",
      "version", "install", "self-update", "bootstrap", "update", "agent", "sdk", "ci", "tools" }) do
      local t = help_text(topic)
      assert.is_nil(t:find("§", 1, true), topic .. ": " .. (t:match("[^\n]*§[^\n]*") or ""))
    end
    assert.is_nil(help_text(nil):find("§", 1, true))
  end)

  it("a command without a topic prints the general usage, exit 0", function()
    local r = run_main({ "frobnicate", "--help" }, root)
    assert.equals(0, r.exit_code)
    assert.is_truthy(r.stdout:find("Usage: lw [command] [args]", 1, true))
  end)

  it("never intercepts args after `--` (they belong to the build tool / program)", function()
    local seen
    local orig = cli.cmd_build
    cli.cmd_build = function(_, args) seen = args; return 0 end
    run_main({ "build", "p", "--", "--help" }, root)
    cli.cmd_build = orig
    assert.is_not_nil(seen)
    assert.equals("--help", seen[#seen])
  end)
end)

describe("CI pattern in `lw help build` / `lw help test`", function()
  it("builds an explicit profile, never relies on --activate", function()
    for _, topic in ipairs({ "build", "test" }) do
      local t = help_text(topic)
      assert.is_nil(t:find("--activate &&", 1, true), topic)
      assert.is_nil(t:find("--activate  &&", 1, true), topic)
      assert.is_truthy(t:find("lw profile create <set> <tool>", 1, true), topic)
      assert.is_truthy(t:find("<set>:<tool>", 1, true), topic)
    end
  end)
end)
