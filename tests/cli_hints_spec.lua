-- Hints that must match the context they are printed in (v0.1.30):
--   * in a pinned context (repo lw.pin — LOOMWORKS_PINNED / a bundle under
--     `.nvim/cache/lua-<ver>`) "Update available" points at `lw update` (which
--     moves the pin), not `lw self-update` (which the pin overrides);
--   * `lw config add` suggests `lw publish` only when the new configuration
--     would actually reach the shared loomworks.json.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local suggestions = require("loomworks.suggestions")

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

describe("update-available hint in a pinned context", function()
  local saved_luaroot, saved_loaded, saved_facts
  before_each(function()
    saved_luaroot = _G.__loomworks_luaroot
    saved_loaded = package.loaded["boot.update"]
    saved_facts = suggestions._host_facts
    package.loaded["boot.update"] = {
      DEFAULT_CHANNEL = "stable",
      resolve_channel = function() return "stable" end,
      resolve_newest_version = function() return "0.2.0" end,
    }
  end)
  after_each(function()
    _G.__loomworks_luaroot = saved_luaroot
    package.loaded["boot.update"] = saved_loaded
    suggestions._host_facts = saved_facts
  end)

  it("a bundle under .nvim/cache/lua-<ver> suggests `lw update`, not `lw self-update`", function()
    _G.__loomworks_luaroot = "C:\\repo\\.nvim\\cache\\lua-0.1.0"
    suggestions._host_facts = function() return nil end
    local out = suggestions.update_check_provider({})
    assert.equals(1, #out)
    assert.equals("Update available", out[1].title)
    assert.matches("run `lw update`", out[1].remedy, 1, true)
    assert.matches("lw.pin", out[1].remedy, 1, true)
    assert.is_nil(out[1].remedy:find("run `lw self-update`", 1, true))
  end)

  it("a pinned host (LOOMWORKS_PINNED) suggests `lw update` too", function()
    _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
    suggestions._host_facts = function()
      return { release_version = "0.1.0", self_update = true, pinned = true, exe = "/opt/lw" }
    end
    local out = suggestions.update_check_provider({})
    assert.equals(1, #out)
    assert.matches("run `lw update`", out[1].remedy, 1, true)
  end)

  it("an unpinned bundle keeps `lw self-update`", function()
    _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
    suggestions._host_facts = function() return nil end
    local out = suggestions.update_check_provider({})
    assert.equals("run `lw self-update`", out[1].remedy)
  end)
end)

describe("`lw config add` publish hint", function()
  local function make_ws()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } }))
    f:close()
    return root
  end

  it("a new local configuration is not told to `lw publish`", function()
    local root = make_ws()
    local r = capture(function() cli.cmd_configuration("add", root, "App", "Mine", "variant:default") end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("added configuration 'Mine'", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("map it into a configuration set", 1, true), r.stdout)
    assert.is_nil(r.stdout:find("lw publish", 1, true), r.stdout)
    vim.fn.delete(root, "rf")
  end)
end)
