-- Shared-directory protection (spec §4.6) compares build directories by
-- their resolved real path: a cached build_dir that spells the SAME physical
-- folder differently from another unit's (a junction / symlink, a Windows 8.3
-- short name like `RUNNER~1`) is still a reference to it. Before, the reverse
-- index `_build_dir_refs` keyed by the plain normalized spelling, so the other
-- reference was missed and the directory was wiped while still in use.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local build_run = require("loomworks.build_run")
local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1

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

--- Record `unit` as built in `dir` (spelled exactly as given).
local function fake_built(ws, unit, dir)
  unit.build_dir_value = dir
  unit.state_value = "built"
  unit.last_built = os.time()
  ws:_sync_build_dir_refs()
end

local function wait(f)
  local done, ok = false, nil
  f:next(function(v) done, ok = true, v ~= false end):catch(function() done, ok = true, false end)
  vim.wait(5000, function() return done end, 10)
  return ok, done
end

--- The real build dir `<root>/out` (with a marker) plus a link `<root>/alias`
--- to it (a junction on Windows, a symlink elsewhere). Returns dir, alias.
local function link_alias(root)
  local dir = root .. "/out"
  vim.fn.mkdir(dir, "p")
  local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
  local alias = root .. "/alias"
  assert(uv.fs_symlink(dir, alias, is_win and { junction = true } or nil))
  assert(uv.fs_stat(alias .. "/marker.txt"), "the alias reaches the build dir")
  return dir, alias
end

--- The real build dir `<root>/Long Build Directory` plus its Windows 8.3
--- short spelling, or nil when the volume has no short names.
local function short_alias(root)
  if not is_win then return nil end
  local dir = root .. "/Long Build Directory"
  vim.fn.mkdir(dir, "p")
  local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
  local out = vim.fn.system({ "cmd", "/c", "for %I in (\"" .. dir:gsub("/", "\\") .. "\") do @echo %~sI" })
  local short = vim.trim(out or ""):gsub("\\", "/")
  if vim.v.shell_error ~= 0 or short == "" or not short:find("~", 1, true) then return nil end
  return dir, short
end

describe("shared build dir protection by real path (spec 4.6)", function()
  local io_mod = require("loomworks.io")
  local real_rm_rf_async, real_rm_rf, real_overseer

  before_each(function()
    real_rm_rf_async, real_rm_rf = io_mod.rm_rf_async, io_mod.rm_rf
    real_overseer = package.loaded["overseer"]
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

  local function keeps_aliased_dir(dir, alias, root)
    local ws, by = load(root)
    local dev, rel = unit_of(by.Dev), unit_of(by.Rel)
    fake_built(ws, dev, dir)
    fake_built(ws, rel, alias)
    ws:_save_cache()

    assert.equals(2, #ws:get_build_dir_refs(dir), "both spellings index one directory")
    assert.equals(2, #ws:get_build_dir_refs(alias), "looked up by either spelling")

    local ok, done = wait(by.Dev:clean())
    assert.is_true(done, "clean settles")
    assert.is_true(ok, "clean succeeds (the shared dir is kept)")
    assert.is_not_nil(uv.fs_stat(dir .. "/marker.txt"),
      "a build dir still referenced under another spelling must survive")
    assert.equals("built", rel.state_value, "the other config's state is untouched")
  end

  it("keeps a dir another unit references through a junction/symlink", function()
    local root = make_ws("${workspace_root}/out")
    local dir, alias = link_alias(root)
    keeps_aliased_dir(dir, alias, root)
  end)

  it("keeps a dir another unit references by its 8.3 short name", function()
    local root = make_ws("${workspace_root}/Long Build Directory")
    local dir, short = short_alias(root)
    if not dir then
      pending("8.3 short names unavailable on this volume")
      return
    end
    keeps_aliased_dir(dir, short, root)
  end)

  it("keeps the dir when the deletion names the aliased spelling", function()
    local root = make_ws("${workspace_root}/out")
    local dir, alias = link_alias(root)
    local ws, by = load(root)
    local dev, rel = unit_of(by.Dev), unit_of(by.Rel)
    fake_built(ws, dev, dir)
    fake_built(ws, rel, alias)
    ws:_save_cache()

    local f, shared = ws:clean_wipe_build_dir({ rel }, alias)
    assert.is_true(shared, "the alias is reported shared with the other unit")
    assert.is_true(wait(f))
    assert.is_not_nil(uv.fs_stat(dir .. "/marker.txt"), "the real dir survives")
    assert.equals("built", dev.state_value)
  end)

  it("still finds a reference indexed before its dir existed (aliased root)", function()
    -- The index keys a missing dir by its normalized spelling; once the dir
    -- exists a lookup resolves it to its real path. Through an aliased root
    -- those differ, and a stale index must not hide the reference.
    local root = make_ws("${workspace_root}/out")
    local rootlink = vim.fn.tempname():gsub("\\", "/")
    assert(uv.fs_symlink(root, rootlink, is_win and { junction = true } or nil))
    local ws, by = load(root)
    local dev, rel = unit_of(by.Dev), unit_of(by.Rel)
    local aliased = rootlink .. "/out"
    fake_built(ws, rel, aliased) -- indexed while <root>/out does not exist
    vim.fn.mkdir(root .. "/out", "p")
    local mf = assert(io.open(root .. "/out/marker.txt", "w")); mf:write("x"); mf:close()
    dev.build_dir_value = root .. "/out"
    dev.state_value = "built"

    assert.equals(1, #ws:get_build_dir_refs(aliased), "the stale-keyed reference is still found")
    local f, shared = ws:clean_wipe_build_dir({ dev }, root .. "/out")
    assert.is_true(shared, "kept: the other unit's reference was indexed under the old key")
    assert.is_true(wait(f))
    assert.is_not_nil(uv.fs_stat(root .. "/out/marker.txt"), "the dir survives")
  end)

  it("groups a clean's wipes of one dir spelled two ways into one batch", function()
    local root = make_ws("${workspace_root}/out")
    local dir, alias = link_alias(root)
    local ws, by = load(root)
    local dev, rel = unit_of(by.Dev), unit_of(by.Rel)
    fake_built(ws, dev, dir)
    fake_built(ws, rel, alias)
    ws:_save_cache()

    local steps = {
      { wipe_build_dir = true, build_dir = dir, unit = dev, name = "App" },
      { wipe_build_dir = true, build_dir = alias, unit = rel, name = "App" },
    }
    local groups = build_run.wipe_groups(ws, steps)
    local n, g = 0, nil
    for _, v in pairs(groups) do n = n + 1; g = v end
    assert.equals(1, n, "one wipe group for the one physical directory")
    assert.equals(2, #g.units)

    -- Both units in one clean: the directory is wiped once, not kept as
    -- "still referenced" by the other spelling.
    local f, shared = ws:clean_wipe_build_dir(g.units, dir)
    assert.is_false(shared, "no reference outside the clean")
    assert.is_true(wait(f))
    assert.is_nil(uv.fs_stat(dir .. "/marker.txt"), "the dir is wiped")
  end)
end)
