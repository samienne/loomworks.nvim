-- `lw clean` on a module that cleans by wiping the build directory (the shell
-- module without `clean_cmd`: `wipe_build_dir`, spec §8.1). The wipe is a
-- build-directory deletion, so it carries the full deletion safety (spec §4.6,
-- §4.7): the cache says `unknown` before the tree is removed and the unit is
-- reset to unconfigured only after the removal succeeded (never "built" over a
-- missing directory), and a directory still referenced by another config is
-- kept.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local uv = vim.uv or vim.loop

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

--- A shell App with Debug + Release (no clean_cmd => wipe) whose build_dir
--- template is `build_dir`; sets Dev (App=Debug) and Rel (App=Release), with
--- a profile for each.
local function make_ws(build_dir)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { shell = {
    build_dir = build_dir,
    configure_cmd = { "true" },
    build_cmd = { "true" },
    configurations = { Debug = vim.empty_dict(), Release = vim.empty_dict() },
  } } } }
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode(lw)); f:close()
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Rel", "App=Release" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Rel" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

--- Two shell projects A and B (Debug + Release, no clean_cmd => wipe) that
--- both build into `${workspace_root}/build`; profiles Both (A=Debug,
--- B=Debug) and Other (A=Release).
local function make_shared_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  local projects = {}
  for _, name in ipairs({ "A", "B" }) do
    vim.fn.mkdir(root .. "/" .. name, "p")
    projects[name] = { shell = {
      build_dir = "${workspace_root}/build",
      configure_cmd = { "true" },
      build_cmd = { "true" },
      configurations = { Debug = vim.empty_dict(), Release = vim.empty_dict() },
    } }
  end
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = projects })); f:close()
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Both", "A=Debug", "B=Debug" }) end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Other", "A=Release" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Other" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Both", "--activate" }) end)
  return root
end

local function units_of(profile)
  local units = {}
  for _, pp in ipairs(profile:projects()) do
    units[#units + 1] = assert(pp._config_unit, "profile project has no config unit")
  end
  return units
end

local function load(root)
  local ws = assert(cli._load_workspace(root, false))
  local by = {}
  for _, p in ipairs(ws._profiles) do local cs = p:config_set(); by[(cs and cs.name) or p.key] = p end
  return ws, by
end

local function unit_of(profile)
  local pp = assert(profile:projects()[1], "profile has no project")
  return assert(pp._config_unit, "profile project has no config unit")
end

--- Fake a built build directory on disk + on the unit.
local function fake_built(ws, unit, dir)
  vim.fn.mkdir(dir, "p")
  local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
  unit.build_dir_value = dir
  unit.state_value = "built"
  unit.last_built = os.time()
  ws:_sync_build_dir_refs()
end

local function cached_state(root, unit)
  local f = assert(io.open(root .. "/.nvim/loomworks.cache.json", "r"))
  local data = vim.json.decode(f:read("*a")); f:close()
  for _, c in pairs(data.build_dirs or {}) do
    if c.project_key == unit._project.key and c.config_key == unit._config_key then return c end
  end
  return nil
end

describe("lw clean (wipe_build_dir)", function()
  local io_mod = require("loomworks.io")
  local real_rm_rf_async, real_rm_rf

  before_each(function()
    real_rm_rf_async, real_rm_rf = io_mod.rm_rf_async, io_mod.rm_rf
    -- Synchronous, no-subprocess removal (see cli_reset_spec for why).
    io_mod.rm_rf_async = function(dir, cb)
      vim.fn.delete(dir, "rf")
      if cb then vim.schedule(function() cb(true, nil) end) end
      return require("loomworks.future").resolved(true)
    end
    io_mod.rm_rf = function(dir) vim.fn.delete(dir, "rf"); return true end
  end)

  after_each(function()
    io_mod.rm_rf_async, io_mod.rm_rf = real_rm_rf_async, real_rm_rf
  end)

  it("resets the unit to unconfigured after the wipe (never 'built' over a removed dir)", function()
    local root = make_ws("${workspace_root}/out/${configuration}")
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    local dir = root .. "/out/Debug"
    fake_built(ws, unit, dir)
    ws:_save_cache()

    local r = capture(function() return cli.cmd_clean(ws, by.Dev.key) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.is_nil(uv.fs_stat(dir), "the build dir is wiped")
    assert.is_nil(unit.state_value, "unit no longer claims a build state")
    local c = cached_state(root, unit)
    assert.is_true(c == nil or (c.state == nil and c.last_built == nil),
      "persisted cache no longer claims built: " .. vim.inspect(c))
  end)

  it("marks the cache unknown on disk before the tree is removed", function()
    local root = make_ws("${workspace_root}/out/${configuration}")
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    local dir = root .. "/out/Debug"
    fake_built(ws, unit, dir)
    ws:_save_cache()

    local seen
    io_mod.rm_rf_async = function(d, cb)
      local c = cached_state(root, unit)
      seen = c and c.state
      vim.fn.delete(d, "rf")
      if cb then vim.schedule(function() cb(true, nil) end) end
      return require("loomworks.future").resolved(true)
    end
    io_mod.rm_rf = function(d)
      local c = cached_state(root, unit)
      seen = c and c.state
      vim.fn.delete(d, "rf"); return true
    end

    local r = capture(function() return cli.cmd_clean(ws, by.Dev.key) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.equals("unknown", seen)
  end)

  it("keeps a build dir still referenced by another configuration", function()
    local root = make_ws("${workspace_root}/out")
    local ws, by = load(root)
    local dev, rel = unit_of(by.Dev), unit_of(by.Rel)
    local dir = root .. "/out"
    fake_built(ws, dev, dir)
    fake_built(ws, rel, dir)
    ws:_save_cache()

    local r = capture(function() return cli.cmd_clean(ws, by.Dev.key) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.is_not_nil(uv.fs_stat(dir .. "/marker.txt"), "shared build dir must survive")
    assert.equals("built", rel.state_value, "the other config's state is untouched")
  end)
  it("fails and leaves the cache unknown when the removal fails", function()
    local root = make_ws("${workspace_root}/out/${configuration}")
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    local dir = root .. "/out/Debug"
    fake_built(ws, unit, dir)
    ws:_save_cache()
    io_mod.rm_rf_async = function(_, cb)
      if cb then vim.schedule(function() cb(false, "boom") end) end
      return require("loomworks.future").resolved(false)
    end
    cli._reset_verify_ms = 100

    local r = capture(function() return cli.cmd_clean(ws, by.Dev.key) end)
    cli._reset_verify_ms = nil
    assert.is_not_nil(r.exit_code, "clean must fail")
    assert.matches("could not remove", r.stderr .. r.stdout)
    assert.equals("unknown", unit.state_value)
    assert.equals("unknown", cached_state(root, unit).state)
  end)
  it("wipes a build dir shared only by units of the same profile clean", function()
    local root = make_shared_ws()
    local ws, by = load(root)
    local units = units_of(by.Both)
    assert.equals(2, #units)
    local dir = root .. "/build"
    for _, u in ipairs(units) do fake_built(ws, u, dir) end
    ws:_save_cache()

    local r = capture(function() return cli.cmd_clean(ws, by.Both.key) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.is_nil(uv.fs_stat(dir), "the dir shared only within the clean is wiped")
    assert.is_nil((r.stdout .. r.stderr):find("kept", 1, true),
      "not reported as kept: no config outside the clean uses it: " .. r.stdout)
    for _, u in ipairs(units) do
      assert.is_nil(u.state_value, "unit reset after the wipe")
    end
  end)

  it("keeps a dir shared within the clean that a unit outside it references", function()
    local root = make_shared_ws()
    local ws, by = load(root)
    local units = units_of(by.Both)
    local other = units_of(by.Other)[1]
    local dir = root .. "/build"
    for _, u in ipairs(units) do fake_built(ws, u, dir) end
    fake_built(ws, other, dir)
    ws:_save_cache()

    local r = capture(function() return cli.cmd_clean(ws, by.Both.key) end)
    assert.is_nil(r.exit_code, r.stderr .. r.stdout)
    assert.is_not_nil(uv.fs_stat(dir .. "/marker.txt"), "dir referenced outside the clean survives")
    assert.equals("built", other.state_value, "the outside config's state is untouched")
  end)

  it("fails when the removal fails for a unit with no cached build dir", function()
    local root = make_ws("${workspace_root}/out")
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    local dir = root .. "/out"
    vim.fn.mkdir(dir, "p")
    unit.build_dir_value = nil
    unit.state_value = "configured"
    ws:_sync_build_dir_refs()
    ws:_save_cache()
    -- The removal fails but the directory vanishes anyway (e.g. removed
    -- concurrently): the deletion's own outcome must decide, not a re-stat.
    io_mod.rm_rf_async = function(d, cb)
      vim.fn.delete(d, "rf")
      if cb then vim.schedule(function() cb(false, "boom") end) end
      return require("loomworks.future").resolved(false)
    end

    local r = capture(function() return cli.cmd_clean(ws, by.Dev.key) end)
    assert.is_not_nil(r.exit_code, "a failed removal must not be reported as success")
    assert.matches("could not remove", r.stderr .. r.stdout)
  end)
end)
