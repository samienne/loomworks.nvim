-- `lw config rename` / `lw configset rename` — CLI convenience wrappers over the
-- editor's atomic mutations (Project:rename_configuration /
-- Workspace:rename_configuration_set). No core/data-model change: the rename
-- propagates to config-set mappings and profiles, persists to the working copy,
-- and survives a fresh reload. These specs pin the on-disk round-trip, the
-- propagation, the `mv` alias, and the error surfaces (not-user-declared,
-- collision, invalid name).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- Run `fn` with io.write / io.stderr / os.exit captured, so a die() path is
-- observable (exit_code set, no process kill) instead of terminating busted.
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

--- A temp workspace with a typescript App, a user `Debug` config (inheriting
--- variant:default), a `Dev` set (App=Debug) and an active `Dev` profile.
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { typescript = vim.empty_dict() } } }
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

-- ---------------------------------------------------------------------------
-- lw config rename <project> <old> <new>
-- ---------------------------------------------------------------------------
describe("lw config rename (on-disk)", function()
  it("renames a user config; persists, reloads, and repoints the set mapping", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("rename", root, "App", "Debug", "DebugX")
    end)
    assert.is_nil(r.exit_code) -- no die()
    -- Confirmation names the old -> new pair (old snapshotted before mutation).
    assert.is_truthy(r.stdout:find("App/Debug", 1, true))
    assert.is_truthy(r.stdout:find("App/DebugX", 1, true))

    -- Working copy: the config is renamed in place, old key gone.
    local user = read_user(root)
    local cfgs = user.projects.App.typescript.configurations
    assert.is_truthy(cfgs.DebugX)
    assert.is_nil(cfgs.Debug)
    -- The set that mapped App=Debug now maps App=DebugX (propagation).
    assert.equals("DebugX", user.configuration_sets.Dev.App)

    -- A FRESH command reloads from disk and shows the new name.
    local g = capture(function() cli.cmd_configuration("list", root, "App") end)
    assert.is_truthy(g.stdout:find("DebugX", 1, true))
    -- `configset show` re-derives the mapping to the new name too.
    local s = capture(function()
      cli.cmd_cset("show", root, { "configuration-set", "show", "Dev" })
    end)
    assert.is_truthy(s.stdout:find("DebugX", 1, true))
  end)

  it("the `mv` alias renames too", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("mv", root, "App", "Debug", "DebugY")
    end)
    assert.is_nil(r.exit_code)
    local cfgs = read_user(root).projects.App.typescript.configurations
    assert.is_truthy(cfgs.DebugY)
    assert.is_nil(cfgs.Debug)
  end)

  it("renaming a module-generated config (variant:default) errors", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("rename", root, "App", "variant:default", "Foo")
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("could not rename configuration", 1, true))
    assert.is_truthy(r.stderr:find("not found", 1, true))
    -- Nothing renamed.
    local cfgs = read_user(root).projects.App.typescript.configurations
    assert.is_truthy(cfgs.Debug)
    assert.is_nil(cfgs.Foo)
  end)

  it("a colliding new name errors (an existing user config)", function()
    local root = make_ws()
    -- A second user config to collide with.
    capture(function() cli.cmd_configuration("add", root, "App", "Release", "variant:default") end)
    local r = capture(function()
      cli.cmd_configuration("rename", root, "App", "Debug", "Release")
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("could not rename configuration", 1, true))
    -- Debug survives the failed rename.
    assert.is_truthy(read_user(root).projects.App.typescript.configurations.Debug)
  end)

  it("an invalid new name errors", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_configuration("rename", root, "App", "Debug", "bad/name")
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("could not rename configuration", 1, true))
    assert.is_truthy(read_user(root).projects.App.typescript.configurations.Debug)
  end)

  it("errors on missing operands", function()
    local root = make_ws()
    local r = capture(function() cli.cmd_configuration("rename", root, "App", "Debug") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("usage: lw config rename", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
-- lw configset rename <old> <new>
-- ---------------------------------------------------------------------------
describe("lw configset rename (on-disk)", function()
  it("renames a set; persists, reloads, and re-derives referencing profiles", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("rename", root, { "configuration-set", "rename", "Dev", "Development" })
    end)
    assert.is_nil(r.exit_code)
    assert.is_truthy(r.stdout:find("Dev", 1, true))
    assert.is_truthy(r.stdout:find("Development", 1, true))

    local user = read_user(root)
    assert.is_truthy(user.configuration_sets.Development)
    assert.is_nil(user.configuration_sets.Dev)
    -- The profile that referenced the set follows it and re-derives its key.
    assert.equals("Development", user.profiles.Development.configuration_set)
    assert.is_nil(user.profiles.Dev)
    assert.equals("Development", user.active_profile)

    -- A FRESH command reloads from disk and shows the new set name.
    local g = capture(function() cli.cmd_cset("list", root) end)
    assert.is_truthy(g.stdout:find("Development", 1, true))
  end)

  it("the `mv` alias renames too", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("mv", root, { "configuration-set", "mv", "Dev", "Staging" })
    end)
    assert.is_nil(r.exit_code)
    local user = read_user(root)
    assert.is_truthy(user.configuration_sets.Staging)
    assert.is_nil(user.configuration_sets.Dev)
  end)

  it("a colliding new name errors", function()
    local root = make_ws()
    capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Other", "App=Debug" }) end)
    local r = capture(function()
      cli.cmd_cset("rename", root, { "configuration-set", "rename", "Dev", "Other" })
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("could not rename configuration set", 1, true))
    assert.is_truthy(r.stderr:find("already exists", 1, true))
    -- Both sets survive.
    local user = read_user(root)
    assert.is_truthy(user.configuration_sets.Dev)
    assert.is_truthy(user.configuration_sets.Other)
  end)

  it("an invalid new name errors", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("rename", root, { "configuration-set", "rename", "Dev", "bad/name" })
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("could not rename configuration set", 1, true))
    assert.is_truthy(read_user(root).configuration_sets.Dev)
  end)

  it("an unknown set errors before any rename", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("rename", root, { "configuration-set", "rename", "Nope", "X" })
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("no configuration set 'Nope'", 1, true))
  end)

  it("errors on missing operands", function()
    local root = make_ws()
    local r = capture(function()
      cli.cmd_cset("rename", root, { "configuration-set", "rename", "Dev" })
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("usage: lw configset rename", 1, true))
  end)
end)
