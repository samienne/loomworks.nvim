-- The editor's clean (`Profile:clean` / `ConfigUnit:clean`) of a module that
-- cleans by wiping the build directory (the shell module without `clean_cmd`:
-- `wipe_build_dir`, spec §8.1). The wipe is a build-directory deletion, so it
-- carries the full deletion safety (spec §4.6, §4.7), exactly like `lw clean`
-- (tests/cli_clean_wipe_spec.lua): the cache says `unknown` on disk before the
-- tree is removed, the unit is reset to unconfigured only after the removal
-- succeeded, a failed removal leaves it `unknown`, and a directory still
-- referenced by another config is kept.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local uv = vim.uv or vim.loop

local function quiet(fn)
  local rw, rs = io.write, io.stderr
  io.write = function() end
  io.stderr = { write = function() end }
  local ok, err = pcall(fn)
  io.write, io.stderr = rw, rs
  if not ok then error(err, 0) end
end

--- A shell App with Debug + Release (no clean_cmd => wipe) whose build_dir
--- template is `build_dir`; profiles Dev (App=Debug) and Rel (App=Release).
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
  quiet(function()
    cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" })
    cli.cmd_cset("create", root, { "configuration-set", "create", "Rel", "App=Release" })
    cli.cmd_profile_create(root, { "profile", "create", "Rel" })
    cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" })
  end)
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
  quiet(function()
    cli.cmd_cset("create", root, { "configuration-set", "create", "Both", "A=Debug", "B=Debug" })
    cli.cmd_cset("create", root, { "configuration-set", "create", "Other", "A=Release" })
    cli.cmd_profile_create(root, { "profile", "create", "Other" })
    cli.cmd_profile_create(root, { "profile", "create", "Both", "--activate" })
  end)
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

--- Wait for a Future; returns ok (resolved) and settled.
local function wait(f)
  local done, ok = false, nil
  f:next(function() done, ok = true, true end):catch(function() done, ok = true, false end)
  vim.wait(5000, function() return done end, 10)
  return ok, done
end

--- Make the clean's per-project wipes overlap, as they do in the editor when
--- a running task has to be stopped first or the rm-rf subprocess is slow:
--- stopping tasks and the removal both complete asynchronously.
local function overlap_deletions(ws, io_mod)
  ws.stop_tasks_then = function()
    return require("loomworks.future").create(function(resolve)
      vim.defer_fn(function() resolve(true) end, 20)
    end)
  end
  io_mod.rm_rf_async = function(dir, cb)
    vim.defer_fn(function()
      vim.fn.delete(dir, "rf")
      if cb then cb(true, nil) end
    end, 30)
    return require("loomworks.future").resolved(true)
  end
end

describe("editor clean (wipe_build_dir)", function()
  local io_mod = require("loomworks.io")
  local real_rm_rf_async, real_rm_rf, real_overseer

  before_each(function()
    real_rm_rf_async, real_rm_rf = io_mod.rm_rf_async, io_mod.rm_rf
    real_overseer = package.loaded["overseer"]
    -- The wipe spawns no overseer task; the clean runner only needs the module.
    package.loaded["overseer"] = real_overseer or {}
    io_mod.rm_rf_async = function(dir, cb)
      vim.fn.delete(dir, "rf")
      if cb then vim.schedule(function() cb(true, nil) end) end
      return require("loomworks.future").resolved(true)
    end
    io_mod.rm_rf = function(dir) vim.fn.delete(dir, "rf"); return true end
  end)

  after_each(function()
    io_mod.rm_rf_async, io_mod.rm_rf = real_rm_rf_async, real_rm_rf
    package.loaded["overseer"] = real_overseer
  end)

  it("Profile:clean resets the unit to unconfigured after the wipe", function()
    local root = make_ws("${workspace_root}/out/${configuration}")
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    local dir = root .. "/out/Debug"
    fake_built(ws, unit, dir)
    ws:_save_cache()

    local ok, done = wait(by.Dev:clean())
    assert.is_true(done, "clean settles")
    assert.is_true(ok, "clean succeeds")
    assert.is_nil(uv.fs_stat(dir), "the build dir is wiped")
    assert.is_nil(unit.state_value, "unit no longer claims a build state")
    assert.is_false(unit:is_deleting())
    local c = cached_state(root, unit)
    assert.is_true(c == nil or (c.state == nil and c.last_built == nil),
      "persisted cache no longer claims a state: " .. vim.inspect(c))
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

    local ok = wait(unit:clean())
    assert.is_true(ok)
    assert.equals("unknown", seen)
    assert.is_nil(unit.state_value, "reset only after the removal succeeded")
  end)

  it("keeps a build dir still referenced by another configuration", function()
    local root = make_ws("${workspace_root}/out")
    local ws, by = load(root)
    local dev, rel = unit_of(by.Dev), unit_of(by.Rel)
    local dir = root .. "/out"
    fake_built(ws, dev, dir)
    fake_built(ws, rel, dir)
    ws:_save_cache()

    local ok = wait(by.Dev:clean())
    assert.is_true(ok)
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

    local ok, done = wait(by.Dev:clean())
    assert.is_true(done, "clean settles")
    assert.is_false(ok, "clean must fail")
    assert.equals("unknown", unit.state_value)
    assert.equals("unknown", cached_state(root, unit).state)
    assert.is_false(unit:is_deleting(), "unit is unmarked after the failure")
  end)
  it("wipes a build dir shared only by units of the same profile clean", function()
    local root = make_shared_ws()
    local ws, by = load(root)
    local units = units_of(by.Both)
    assert.equals(2, #units)
    local dir = root .. "/build"
    for _, u in ipairs(units) do fake_built(ws, u, dir) end
    overlap_deletions(ws, io_mod)
    ws:_save_cache()

    local skipped = {}
    local real_notify = ws._core._deps.notify
    ws._core._deps.notify = function(msg, ...)
      if tostring(msg):find("skipped deleting", 1, true) then skipped[#skipped + 1] = msg end
      return real_notify(msg, ...)
    end

    local ok, done = wait(by.Both:clean())
    assert.is_true(done, "clean settles")
    assert.is_true(ok, "clean succeeds")
    assert.is_nil(uv.fs_stat(dir), "the dir shared only within the clean is wiped")
    ws._core._deps.notify = real_notify
    assert.same({}, skipped, "no unit of the clean is treated as an outside reference")
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
    overlap_deletions(ws, io_mod)
    fake_built(ws, other, dir)
    ws:_save_cache()

    local ok = wait(by.Both:clean())
    assert.is_true(ok)
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
    io_mod.rm_rf_async = function(_, cb)
      if cb then vim.schedule(function() cb(false, "boom") end) end
      return require("loomworks.future").resolved(false)
    end

    local ok, done = wait(by.Dev:clean())
    assert.is_true(done, "clean settles")
    assert.is_false(ok, "a failed removal must not be reported as success")
  end)
end)
