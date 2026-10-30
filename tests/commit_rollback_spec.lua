-- A guarded multi-file operation (op_lock.guard, spec §19.3–§19.4) whose
-- commit fails, or which raises, wrote nothing (or not everything): its
-- in-memory change is dropped by reloading the model from the files on disk,
-- so the model never diverges from disk (API.md §11: a refused write changes
-- neither the files nor the model). BACKLOG "A failed commit under
-- op_lock.guard keeps the in-memory change".

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local io_mod = require("loomworks.io")
local user_mod = require("loomworks.user")

local function capture(fn)
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function() end
  io.stderr = { write = function() end }
  os.exit = function() error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
end

--- Workspace: typescript App with a user Debug config, sets Dev and Other,
--- profiles of both (Dev active).
local function make_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/App/tsconfig.json", "w")); f:write("{}"); f:close()
  f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Other", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Other" }) end)
  return root
end

local function find(list, field, value)
  for _, o in pairs(list) do if o[field] == value and not o._removed then return o end end
end

describe("failed commit under the operation lock", function()
  local root, ws, user_path, user_before, config_before
  local function fail_commit()
    ws._txn_finish = function(self, t) self:_txn_abort(t); return false, "commit failed" end
  end
  local function files_unchanged()
    assert.equals(user_before, io_mod.read_file(user_path))
    assert.equals(config_before, io_mod.read_file(root .. "/loomworks.json"))
  end
  --- A later unrelated save is not refused as stale (the baseline is the disk).
  local function later_save_ok()
    ws._txn_finish = nil
    local other = find(ws._profiles, "_configuration_set_name", "Other")
    local r = require("loomworks.model_commands").profile_set_active(other)
    assert.equals("ok", r.outcome, r.message)
  end

  before_each(function()
    root = make_root()
    ws = assert(cli._load_workspace(root, false))
    user_path = user_mod.filepath(root)
    user_before = io_mod.read_file(user_path)
    config_before = io_mod.read_file(root .. "/loomworks.json")
  end)

  it("rename_project: the project keeps its key", function()
    fail_commit()
    local app = find(ws._projects, "key", "App")
    local ok, err = ws:rename_project(app, "App2")
    assert.is_false(ok)
    assert.equals("commit failed", err)
    files_unchanged()
    assert.equals(app, find(ws._projects, "key", "App"))
    assert.is_nil(find(ws._projects, "key", "App2"))
    later_save_ok()
  end)

  it("rename_configuration_set: the set keeps its name", function()
    fail_commit()
    local dev = find(ws._config_sets, "name", "Dev")
    assert.is_false((ws:rename_configuration_set(dev, "Dev2")))
    files_unchanged()
    assert.equals(dev, find(ws._config_sets, "name", "Dev"))
    assert.is_nil(find(ws._config_sets, "name", "Dev2"))
    later_save_ok()
  end)

  it("remove_profile: the profile stays", function()
    fail_commit()
    local other = find(ws._profiles, "_configuration_set_name", "Other")
    assert.is_false((ws:remove_profile(other)))
    files_unchanged()
    assert.is_truthy(find(ws._profiles, "_configuration_set_name", "Other"))
    later_save_ok()
  end)

  it("Project:rename_configuration: the configuration keeps its name", function()
    fail_commit()
    local app = find(ws._projects, "key", "App")
    local debug = app:get_configuration("Debug")
    assert.is_false((app:rename_configuration("Debug", "Dbg", app:get_configuration("Debug"):declared_data())))
    files_unchanged()
    app = find(ws._projects, "key", "App")
    assert.equals(debug, app:get_configuration("Debug"))
    assert.is_nil(app:get_configuration("Dbg"))
    later_save_ok()
  end)

  it("publish: the shared baseline, removed-upstream flags and intents stay", function()
    local app = find(ws._projects, "key", "App")
    local cs = find(ws._config_sets, "name", "Dev")
    app._removed_upstream = true
    local intent = cs._intent
    local baseline = vim.deepcopy(ws._shared_baseline)
    fail_commit()
    assert.is_false((ws:publish()))
    files_unchanged()
    assert.same(baseline, ws._shared_baseline)
    assert.is_true(find(ws._projects, "key", "App")._removed_upstream)
    assert.equals(intent, find(ws._config_sets, "name", "Dev")._intent)
    later_save_ok()
  end)

  it("a guarded method that raises leaves the model as on disk", function()
    local real = ws._save_user
    ws._save_user = function() error("boom") end
    assert.has_error(function() ws:rename_project(find(ws._projects, "key", "App"), "App2") end)
    ws._save_user = real
    files_unchanged()
    assert.is_truthy(find(ws._projects, "key", "App"))
    assert.is_nil(find(ws._projects, "key", "App2"))
    later_save_ok()
  end)
end)

--- Workspace: a shell App (it has config units) with Debug in loomworks.json
--- and a user configuration Dbg; sets Dev (App=Debug), Other (App=Dbg);
--- profiles of both (Dev active).
local function make_shell_root()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { shell = {
    build_dir = "${workspace_root}/.nvim/build/${project}/${configuration}",
    configure_cmd = { "true" },
    build_cmd = { "true" },
    configurations = { Debug = vim.empty_dict() },
  } } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Dbg", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_cset("create", root, { "configset", "create", "Other", "App=Dbg" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Other" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

describe("failed commit keeps config unit and profile identity", function()
  local root, ws, units, ids, profiles, active
  local function fail_commit()
    ws._txn_finish = function(self, t) self:_txn_abort(t); return false, "commit failed" end
  end
  local function live_units()
    local out = {}
    for _, u in pairs(ws._config_units) do if not u._removed then out[u] = true end end
    return out
  end
  local function cache_keys()
    local keys = {}
    for k in pairs(ws:_serialize_cache().build_dirs or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
  end
  --- Every unit and profile is the same object, under the same id / key.
  local function identity_kept()
    assert.same(units, live_units())
    for u, id in pairs(ids) do
      assert.equals(id, u.id)
      assert.is_false(u._removed == true)
    end
    for pr, key in pairs(profiles) do
      assert.equals(key, pr.key)
      assert.is_false(pr._removed == true)
      assert.equals(pr, find(ws._profiles, "key", key))
    end
    assert.equals(active, ws._active_profile)
  end

  before_each(function()
    root = make_shell_root()
    ws = assert(cli._load_workspace(root, false))
    units, ids, profiles = live_units(), {}, {}
    for u in pairs(units) do ids[u] = u.id end
    assert.is_true(next(ids) ~= nil, "fixture has no config units")
    for _, pr in pairs(ws._profiles) do profiles[pr] = pr.key end
    active = ws._active_profile
    assert.is_truthy(active)
  end)

  it("rename_project", function()
    fail_commit()
    assert.is_false((ws:rename_project(find(ws._projects, "key", "App"), "App2")))
    identity_kept()
  end)

  it("rename_project with a running build: no ghost unit, no extra cache entry", function()
    local before = cache_keys()
    local running = next(units)
    running._action = "build"
    fail_commit()
    assert.is_false((ws:rename_project(find(ws._projects, "key", "App"), "App2")))
    identity_kept()
    assert.same(before, cache_keys())
    running._action = nil
  end)

  it("rename_configuration_set: the active profile stays the same object", function()
    fail_commit()
    assert.is_false((ws:rename_configuration_set(find(ws._config_sets, "name", "Dev"), "Dev2")))
    identity_kept()
  end)

  it("Project:rename_configuration: units keep id, variant and build dir", function()
    local app = find(ws._projects, "key", "App")
    local fields = {}
    for u in pairs(units) do fields[u] = { u._variant, u._config_key, u._build_dir, u.build_dir_value } end
    fail_commit()
    assert.is_false((app:rename_configuration("Dbg", "Dbg2", app:get_configuration("Dbg"):declared_data())))
    identity_kept()
    for u, f in pairs(fields) do
      assert.same(f, { u._variant, u._config_key, u._build_dir, u.build_dir_value })
    end
  end)
end)

-- A multi-file commit whose apply step fails after the journal was written
-- (spec §19.4 commit point): the writer, still holding the operation lock,
-- rolls the journal forward itself, so a "refused" write never lands later.
describe("failed apply after the commit point", function()
  local root, ws, cache_path, real_rename, injected
  -- The workspace names its files by its resolved root, which can be spelled
  -- differently from `root` (a Windows 8.3 short temp dir like `RUNNER~1`):
  -- match the target by the identity of its directory, not by its spelling.
  local function same_file(a, b)
    local function key(p)
      p = p:gsub("\\", "/")
      local dir, base = p:match("^(.*)/([^/]+)$")
      return ((vim.uv.fs_realpath(dir) or dir):gsub("\\", "/")) .. "/" .. base
    end
    local ka, kb = key(a), key(b)
    if vim.fn.has("win32") == 1 then ka, kb = ka:lower(), kb:lower() end
    return ka == kb
  end
  local function fail_rename_to(target, times)
    injected = 0
    vim.uv.fs_rename = function(from, to, ...)
      if from:find(".txn-", 1, true) and injected < times and same_file(to, target) then
        injected = injected + 1
        return nil, "EIO: injected", "EIO"
      end
      return real_rename(from, to, ...)
    end
  end
  local function journal() return io_mod.read_file(root .. "/.nvim/loomworks.txn.json") end

  before_each(function()
    root = make_root()
    ws = assert(cli._load_workspace(root, false))
    cache_path = root .. "/.nvim/loomworks.cache.json"
    real_rename = vim.uv.fs_rename
  end)
  after_each(function() vim.uv.fs_rename = real_rename end)

  it("is completed at once and reported committed", function()
    fail_rename_to(cache_path, 1)
    local ok, err = ws:rename_project(find(ws._projects, "key", "App"), "App2")
    vim.uv.fs_rename = real_rename
    assert.equals(1, injected)
    assert.is_true(ok, err)
    assert.is_nil(journal())
    assert.truthy(io_mod.read_file(user_mod.filepath(root)):find("App2", 1, true))
    assert.is_truthy(find(ws._projects, "key", "App2"))
    local other = find(ws._profiles, "_configuration_set_name", "Other")
    local r = require("loomworks.model_commands").profile_set_active(other)
    assert.equals("ok", r.outcome, r.message)
  end)

  it("that cannot be completed is a failure, the model as on disk", function()
    fail_rename_to(cache_path, 1000)
    local ok, err = ws:rename_project(find(ws._projects, "key", "App"), "App2")
    vim.uv.fs_rename = real_rename
    assert.is_true(injected > 1, "the apply and its completion both failed")
    assert.is_false(ok)
    assert.truthy(tostring(err):find("commit", 1, true))
    assert.is_truthy(journal())
  end)
end)
