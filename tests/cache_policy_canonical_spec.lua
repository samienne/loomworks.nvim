-- The `cache` policy (core §1.3.2) is stored in its canonical lower-case form
-- wherever it can be set — `lw profile set … cache`, `lw config set
-- variables.cache` / `overrides.<family>.cache`, and the editor's
-- save_configuration path — so `SCCACHE` then `sccache` is "(unchanged)"
-- rather than a rewrite. Canonical = `compiler_cache.normalize_policy`:
-- `auto`, `off` (for every off-synonym), or the launcher name.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local cc = require("loomworks.compiler_cache")

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

describe("compiler_cache.canonical_policy", function()
  it("lower-cases launcher names and folds off/auto synonyms", function()
    assert.equals("sccache", cc.canonical_policy("SCCACHE"))
    assert.equals("ccache", cc.canonical_policy(" CCache "))
    assert.equals("off", cc.canonical_policy("None"))
    assert.equals("off", cc.canonical_policy("FALSE"))
    assert.equals("off", cc.canonical_policy("no"))
    assert.equals("auto", cc.canonical_policy("AUTO"))
  end)

  it("leaves non-strings, empty strings and invalid values untouched", function()
    assert.is_nil(cc.canonical_policy(nil))
    assert.equals(false, cc.canonical_policy(false))
    assert.equals("", cc.canonical_policy(""))
    assert.equals("Bogus", cc.canonical_policy("Bogus"))
  end)
end)

describe("on-disk CLI stores the canonical cache policy", function()
  local function make_ws()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({
      projects = { App = { typescript = vim.empty_dict() } },
      configuration_sets = { dev = { App = "default" } },
    }))
    f:close()
    return root
  end
  local function user_json(root)
    local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "r"))
    local s = f:read("*a"); f:close()
    return s
  end
  local function get(root, cfg, param)
    return capture(function() cli.cmd_configuration("get", root, "App", cfg, param) end).stdout
  end

  after_each(function() cli._set_create_intent(nil) end)

  it("`lw profile set … cache SCCACHE` stores sccache; `sccache` is then unchanged", function()
    local root = make_ws()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "dev" }) end)
    local r = capture(function()
      cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "SCCACHE" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("set App/cache = sccache", 1, true), r.stdout)
    local uj = user_json(root)
    assert.is_truthy(uj:find('"cache":%s*"sccache"'), uj)
    assert.is_nil(uj:find("SCCACHE", 1, true), uj)
    local again = capture(function()
      cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "sccache" })
    end)
    assert.is_truthy(again.stdout:find("(unchanged)", 1, true), again.stdout)
    local none = capture(function()
      cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "None" })
    end)
    assert.is_truthy(none.stdout:find("set App/cache = off", 1, true), none.stdout)
    -- `false` is the same policy as the stored `off` → unchanged.
    local f = capture(function()
      cli.cmd_profile_set(root, { "profile", "set", "dev", "App", "cache", "false" })
    end)
    assert.is_truthy(f.stdout:find("(unchanged)", 1, true), f.stdout)
    vim.fn.delete(root, "rf")
  end)

  it("`lw config set variables.cache` / `overrides.<family>.cache` store canonical values", function()
    local root = make_ws()
    cli._set_create_intent("local")
    capture(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
    local r = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "variables.cache", "SCCACHE")
    end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.equals("sccache\n", get(root, "Mine", "variables.cache"))
    local again = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "variables.cache", "sccache")
    end)
    assert.is_truthy(again.stdout:find("variables.cache = sccache (unchanged)", 1, true), again.stdout)

    local ov = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "overrides.msvc.cache", "CCache")
    end)
    assert.is_nil(ov.exit_code, ov.stderr)
    assert.equals("ccache\n", get(root, "Mine", "overrides.msvc.cache"))
    local ov2 = capture(function()
      cli.cmd_configuration("set", root, "App", "Mine", "overrides.msvc.cache", "CCACHE")
    end)
    assert.is_truthy(ov2.stdout:find("(unchanged)", 1, true), ov2.stdout)
    vim.fn.delete(root, "rf")
  end)

  it("the editor's save_configuration path stores canonical values", function()
    local root = make_ws()
    local ws = cli._load_workspace(root, false)
    local proj
    for _, p in pairs(ws._projects) do if p.key == "App" then proj = p end end
    local ok, err = proj:save_configuration("Ed", {
      variant = "default",
      variables = { cache = "SCCache" },
      overrides = { gcc = { cache = "NONE" } },
    })
    assert.is_true(ok, err)
    local cfg = proj:get_configuration("Ed")
    assert.equals("sccache", cfg.variables.cache)
    assert.equals("off", cfg._overrides.gcc.cache)
    vim.fn.delete(root, "rf")
  end)
end)
