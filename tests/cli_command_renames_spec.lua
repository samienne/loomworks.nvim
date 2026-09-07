-- CLI command renames (#16 follow-up): `settings` (was `config`), `config`
-- (was `configuration`), `configset` (was `configuration-set`), and `profile`
-- promoted, with the old names kept as working-but-unpromoted aliases.
--
-- The load-bearing hazard is that the token `config` FLIPS meaning: it used to
-- edit lw's own settings, and now edits a project's build configuration. These
-- tests pin the new dispatch, the flip, the still-working aliases, and the fact
-- that the aliases are kept OUT of the top-level completion list.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- Run `fn` with io.write / io.stderr / os.exit captured, so a die()/finish()
-- path is observable (exit_code set, no process kill) instead of terminating
-- the runner. Mirrors the helper the other cli specs use.
local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return {
    exit_code = exit_code,
    stdout = table.concat(out_buf),
    stderr = table.concat(err_buf),
  }
end

--- A minimal on-disk workspace (a typescript App) so the workspace-required
--- commands get past the root guard when driven through `main()`.
local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { typescript = vim.empty_dict() } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
  return root
end

--- Drive the real top-level dispatcher (`main()`) with `argv` and LW_ROOT set to
--- `root`, capturing output. Restores `_G.arg` / LW_ROOT afterwards.
local function run_main(argv, root)
  local saved_arg = _G.arg
  local saved_root = vim.env.LW_ROOT
  _G.arg = argv
  vim.env.LW_ROOT = root
  local r = capture(function() cli.main() end)
  _G.arg = saved_arg
  vim.env.LW_ROOT = saved_root
  return r
end

--- Same, but stub the five affected handlers so we observe WHICH one the router
--- reached without running its body. Returns the recorded handler name.
local function route(argv, root)
  local names = { "cmd_settings", "cmd_configuration", "cmd_cset", "cmd_profile", "cmd_profiles" }
  local saved, called = {}, nil
  for _, nm in ipairs(names) do
    saved[nm] = cli[nm]
    cli[nm] = function() called = nm; return 0 end
  end
  run_main(argv, root)
  for _, nm in ipairs(names) do cli[nm] = saved[nm] end
  return called
end

-- ---------------------------------------------------------------------------
-- Dispatch routing — canonical names AND aliases reach the right handler
-- ---------------------------------------------------------------------------
describe("command dispatch (canonical + aliases)", function()
  local root = make_root()

  it("`settings` reaches the settings handler", function()
    assert.equals("cmd_settings", route({ "settings", "list" }, root))
  end)

  it("`config` reaches the project-CONFIGURATION handler (the flip)", function()
    assert.equals("cmd_configuration", route({ "config", "list" }, root))
  end)

  it("`configuration` (alias) reaches the same configuration handler", function()
    assert.equals("cmd_configuration", route({ "configuration", "list" }, root))
  end)

  it("`cfg` (alias) reaches the configuration handler", function()
    assert.equals("cmd_configuration", route({ "cfg", "list" }, root))
  end)

  it("`config` does NOT reach the settings handler", function()
    assert.are_not.equals("cmd_settings", route({ "config", "list" }, root))
  end)

  it("`configset` reaches the config-set handler", function()
    assert.equals("cmd_cset", route({ "configset", "list" }, root))
  end)

  it("`configuration-set` (alias) reaches the config-set handler", function()
    assert.equals("cmd_cset", route({ "configuration-set", "list" }, root))
  end)

  it("`cs` (alias) reaches the config-set handler", function()
    assert.equals("cmd_cset", route({ "cs", "list" }, root))
  end)

  it("`profile` reaches the profile handler", function()
    assert.equals("cmd_profile", route({ "profile", "list" }, root))
  end)

  it("`profiles` (alias) reaches the profile-list handler", function()
    assert.equals("cmd_profiles", route({ "profiles" }, root))
  end)
end)

-- ---------------------------------------------------------------------------
-- The flip, end to end: `settings` owns lw's own key/value storage; `config`
-- no longer does.
-- ---------------------------------------------------------------------------
describe("settings vs config storage (the flip)", function()
  --- Point lw's own-settings file (config_dir) at a throwaway dir so the test
  --- never reads or writes the developer's real settings.
  local function with_isolated_settings(fn)
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local prev_appdata, prev_xdg = vim.env.APPDATA, vim.env.XDG_CONFIG_HOME
    vim.env.APPDATA = dir
    vim.env.XDG_CONFIG_HOME = dir
    local ok, err = pcall(fn)
    vim.env.APPDATA = prev_appdata
    vim.env.XDG_CONFIG_HOME = prev_xdg
    if not ok then error(err) end
  end

  it("`lw settings get` reads back what `lw settings set` wrote", function()
    with_isolated_settings(function()
      local root = make_root()
      local set = run_main({ "settings", "set", "dev-lua", "/opt/lw/lua" }, root)
      assert.equals(0, set.exit_code)
      local get = run_main({ "settings", "get", "dev-lua" }, root)
      assert.equals(0, get.exit_code)
      assert.is_truthy(get.stdout:find("/opt/lw/lua", 1, true))
    end)
  end)

  it("`lw config get dev-lua` does NOT read lw's own settings anymore", function()
    with_isolated_settings(function()
      local root = make_root()
      run_main({ "settings", "set", "dev-lua", "/opt/lw/lua" }, root)
      -- `config` is now project-configuration: `get` needs <project> <name>
      -- <param>, so `config get dev-lua` errors instead of printing the setting.
      local r = run_main({ "config", "get", "dev-lua" }, root)
      assert.equals(1, r.exit_code)
      assert.is_falsy(r.stdout:find("/opt/lw/lua", 1, true))
      assert.is_truthy(r.stderr:find("lw config get", 1, true))
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Completion / command list: canonical names only, aliases suppressed
-- ---------------------------------------------------------------------------
describe("top-level completion promotes canonical names only", function()
  --- The command-name completion set (cword=1 → the n==0 branch that emits
  --- COMP_COMMANDS), as a name→true lookup so `config` isn't confused with the
  --- `configset` / `configuration` lines it is a substring of.
  local function top_level_commands()
    local r = capture(function() cli.cmd_complete(1, { "lw" }) end)
    local set = {}
    for line in r.stdout:gmatch("[^\r\n]+") do set[line] = true end
    return set
  end

  -- cmd_complete latches the process-global completion flag; reset it so a
  -- later spec in this file (there are none after, but be defensive) that loads
  -- a workspace isn't silently short-circuited.
  after_each(function() cli._reset_modes() end)

  it("offers the canonical names", function()
    local c = top_level_commands()
    assert.is_true(c.settings)
    assert.is_true(c.config)
    assert.is_true(c.configset)
    assert.is_true(c.profile)
  end)

  it("suppresses the unpromoted aliases", function()
    local c = top_level_commands()
    assert.is_nil(c.configuration)
    assert.is_nil(c["configuration-set"])
    assert.is_nil(c.cs)
    assert.is_nil(c.cfg)
    assert.is_nil(c.profiles)
  end)
end)
