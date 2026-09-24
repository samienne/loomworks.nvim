-- CLI wording/UX around the compiler cache and configuration edits:
--   * `lw help cache` (aliases `sccache`, `ccache`) holds the explanations the
--     terse health items point at (headless §16.31);
--   * the `Cache` row points an `auto (off for MSVC-style)` profile at it;
--   * `lw status --cache-stats` with no active profile says why nothing shows;
--   * `lw config set/unset` suggests `lw publish` only for a configuration that
--     reaches the shared loomworks.json (§2.4 effective intent).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, err = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

describe("lw help cache", function()
  it("explains policy, the MSVC-style opt-in, /Z7 + scan, env, not-applied, install, reconfigure", function()
    local r = capture(function() cli.cmd_help("cache") end)
    local t = r.stdout
    for _, needle in ipairs({
      "lw config set <project> <configuration> variables.cache sccache",
      "overrides.msvc.cache", "overrides.clang.cache", "lw profile set",
      "C1041", "/Z7", "CMP0141", "SCAN", "env.SCCACHE_DIR",
      "preset", "Visual Studio", "scoop install sccache", "apt install ccache",
      "--reconfigure",
    }) do
      assert.is_truthy(t:find(needle, 1, true), "missing: " .. needle)
    end
  end)

  it("is reachable as `lw help sccache` and `lw help ccache`", function()
    local base = capture(function() cli.cmd_help("cache") end).stdout
    assert.equals(base, capture(function() cli.cmd_help("sccache") end).stdout)
    assert.equals(base, capture(function() cli.cmd_help("ccache") end).stdout)
  end)

  it("is offered by `lw help` completion", function()
    local r = capture(function() cli.cmd_complete("2", { "lw", "help", "" }) end)
    assert.is_truthy(r.stdout:find("\ncache\n", 1, true) or r.stdout:find("^cache\n"))
  end)
end)

describe("Cache row opt-in pointer", function()
  local function fake_profile(status)
    return {
      key = "dev:msvc", _configuration_set_name = "dev",
      projects = function() return {} end,
      config_set = function() return nil end,
      is_valid = function() return true, {} end,
      tool_for = function() return nil end,
      default_target = function() return nil end,
      compiler_cache_status = function() return status end,
    }
  end
  local function rows(status)
    local p = fake_profile(status)
    local ws = { root = "/ws", _active_profile_key = p.key, _profiles = { p },
      diagnostics = function() return {} end }
    return table.concat(cli._profile_show_rows(ws, p, false), "\n")
  end

  it("`auto (off for MSVC-style)` points at `lw help cache`", function()
    local text = rows({ text = "Cache: auto (off for MSVC-style)", policy = "auto",
      msvc_auto_off = true, applicable = true, present = false, stale = false })
    assert.is_truthy(text:find("auto (off for MSVC-style) — lw help cache", 1, true))
  end)

  it("other statuses carry no pointer", function()
    local text = rows({ text = "Cache: sccache", policy = "sccache", tool = "sccache",
      msvc_auto_off = false, applicable = true, present = true, stale = false })
    assert.is_nil(text:find("lw help cache", 1, true))
  end)
end)

describe("on-disk CLI", function()
  local function make_ws()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = {
      typescript = vim.empty_dict(),
      variables = { warn = { type = "string", default = "" } },
    } } }))
    f:close()
    return root
  end

  after_each(function() cli._set_create_intent(nil) end)

  it("`lw status --cache-stats` with no active profile prints a one-line reason", function()
    local root = make_ws()
    local r = capture(function() cli.cmd_status(root, { cache_stats = true }) end)
    assert.is_truthy(r.stdout:find("no active profile", 1, true))
    assert.is_truthy(r.stdout:find("--cache-stats", 1, true))
    -- Without the flag: nothing about the cache.
    local plain = capture(function() cli.cmd_status(root, {}) end)
    assert.is_nil(plain.stdout:find("--cache-stats", 1, true))
    vim.fn.delete(root, "rf")
  end)

  it("config set/unset on a LOCAL configuration does not suggest `lw publish`", function()
    local root = make_ws()
    cli._set_create_intent("local")
    capture(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
    cli._set_create_intent(nil)
    local set = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "variables.warn", "-Wall")
    end)
    assert.is_truthy(set.stdout:find("App/Mine: set variables.warn", 1, true))
    assert.is_nil(set.stdout:find("lw publish", 1, true))
    local unset = capture(function()
      cli.cmd_configuration("unset", root, "App", "Mine", "variables.warn")
    end)
    assert.is_nil(unset.stdout:find("lw publish", 1, true))
    vim.fn.delete(root, "rf")
  end)

  it("config set on a published (local+shared) configuration still suggests it", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("add", root, "App", "Team", "variant:default") end)
    capture(function() cli.cmd_configuration("publish", root, "App", "Team") end)
    local set = capture(function()
      cli.cmd_configuration("set", root, "App", "Team", "variables.warn", "-Wall")
    end)
    assert.is_truthy(set.stdout:find("lw publish", 1, true))
    vim.fn.delete(root, "rf")
  end)

  it("unset of a never-set param reports `not set` with no publish hint", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("add", root, "App", "Team", "variant:default") end)
    capture(function() cli.cmd_configuration("publish", root, "App", "Team") end)
    local r = capture(function()
      cli.cmd_configuration("unset", root, "App", "Team", "env.NOPE")
    end)
    assert.is_nil(r.exit_code)
    assert.is_truthy(r.stdout:find("App/Team: env.NOPE is not set", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("unset env.NOPE", 1, true))
    assert.is_nil(r.stdout:find("lw publish", 1, true))
    vim.fn.delete(root, "rf")
  end)

  it("the publish hint appears only when a set/unset changed something", function()
    local root = make_ws()
    capture(function() cli.cmd_configuration("add", root, "App", "Team", "variant:default") end)
    capture(function() cli.cmd_configuration("publish", root, "App", "Team") end)
    local first = capture(function()
      cli.cmd_configuration("set", root, "App", "Team", "env.FOO", "1")
    end)
    assert.is_truthy(first.stdout:find("lw publish", 1, true))
    -- Same value again: nothing changed → no hint.
    local again = capture(function()
      cli.cmd_configuration("set", root, "App", "Team", "env.FOO", "1")
    end)
    assert.is_truthy(again.stdout:find("App/Team: env.FOO = 1 (unchanged)", 1, true), again.stdout)
    assert.is_nil(again.stdout:find("lw publish", 1, true))
    local unset = capture(function()
      cli.cmd_configuration("unset", root, "App", "Team", "env.FOO")
    end)
    assert.is_truthy(unset.stdout:find("unset env.FOO", 1, true))
    assert.is_truthy(unset.stdout:find("lw publish", 1, true))
    vim.fn.delete(root, "rf")
  end)

  it("`lw profile unset` of a never-set fill reports `not set`", function()
    local root = make_ws()
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({
      projects = { App = { typescript = vim.empty_dict(),
        variables = { warn = { type = "string", default = "" } } } },
      configuration_sets = { dev = { App = "default" } },
    }))
    f:close()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    local r = capture(function()
      cli.cmd_profile_unset(root, { "profile", "unset", "dev", "App", "warn" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("App/warn is not set", 1, true), r.stdout .. r.stderr)
    vim.fn.delete(root, "rf")
  end)
end)
