-- loomworks.reset_plan — the reset plan shared by the in-process `lw reset`
-- and the workspace daemon (spec §16.30, §19.15 "Reset"): the lock set
-- (every computed build dir), the removal set (dirs on disk to remove), the
-- listing, the plan token (scope + lock set + removal set), and the
-- execution's stop predicate, asked between entries (a stopped reset leaves
-- the cache `unknown` for what it did not finish, never reset).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local reset_plan = require("loomworks.reset_plan")
local BuildDir = require("loomworks.build_dir")
local uv = vim.uv or vim.loop

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

local function load(root)
  local ws = assert(cli._load_workspace(root, false))
  return ws, assert(ws._profiles[1])
end

local function mkdir_marker(dir)
  vim.fn.mkdir(dir, "p")
  local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
end

local function fake_build_dir(ws, profile, dir)
  local unit = assert(profile:projects()[1]._config_unit)
  mkdir_marker(dir)
  unit.build_dir_value = dir
  unit.state_value = "built"
  ws:_sync_build_dir_refs()
  return unit
end

local function add_orphan(ws, root, name)
  local dir = root .. "/.nvim/build/" .. name
  mkdir_marker(dir)
  local bd = BuildDir.new("build/" .. name, dir, {
    state = "built", project_key = name, config_key = name,
    variant = name, type = "typescript", build_dir = dir,
  })
  table.insert(ws._build_dirs, bd)
  return dir, bd
end

local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

describe("reset_plan.token", function()
  it("is stable for the same plan, whatever the order", function()
    local a = reset_plan.token("profile:Dev", { "/w/b/x", "/w/b/y" }, { "/w/b/x" })
    local b = reset_plan.token("profile:Dev", { "/w/b/y", "/w/b/x" }, { "/w/b/x" })
    assert.equals(a, b)
    assert.equals(64, #a)
  end)

  it("changes when the scope, the lock set or the removal set changes", function()
    local base = reset_plan.token("profile:Dev", { "/w/b/x", "/w/b/y" }, { "/w/b/x" })
    assert.are_not.equal(base, reset_plan.token("all", { "/w/b/x", "/w/b/y" }, { "/w/b/x" }))
    assert.are_not.equal(base, reset_plan.token("profile:Rel", { "/w/b/x", "/w/b/y" }, { "/w/b/x" }))
    assert.are_not.equal(base, reset_plan.token("profile:Dev", { "/w/b/x" }, { "/w/b/x" }))
    assert.are_not.equal(base, reset_plan.token("profile:Dev", { "/w/b/x", "/w/b/y" }, {}))
    assert.are_not.equal(base,
      reset_plan.token("profile:Dev", { "/w/b/x", "/w/b/y" }, { "/w/b/x", "/w/b/y" }))
    -- A directory moving from one set to the other is a different plan.
    assert.are_not.equal(reset_plan.token("all", { "/a" }, {}), reset_plan.token("all", {}, { "/a" }))
  end)
end)

describe("reset_plan.plan", function()
  it("locks the computed build dir of a never-built profile and resets nothing", function()
    local ws, profile = load(make_ws())
    local plan = reset_plan.plan(ws, { profile = profile })
    assert.equals("profile", plan.scope)
    assert.equals("profile '" .. profile.key .. "'", plan.label)
    assert.equals(0, #plan.removal_dirs)
    assert.is_false(plan.state_to_clear)
    assert.is_true(reset_plan.is_empty(plan))
    assert.equals("nothing to reset for profile '" .. profile.key
      .. "' — no build directories to remove.", reset_plan.nothing_message(plan))
    local pp_dir = profile:projects()[1]:build_dir()
    if pp_dir then assert.is_true(contains(plan.lock_dirs, pp_dir)) end
  end)

  it("lists the profile's build dir on disk, its unit and a stable token", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    local plan = reset_plan.plan(ws, { profile = profile })
    assert.same({ dir }, plan.removal_dirs)
    assert.is_true(contains(plan.lock_dirs, dir))
    assert.same({ unit }, plan.units)
    assert.is_false(reset_plan.is_empty(plan))
    assert.same({
      "Will remove 1 build directory and reset profile '" .. profile.key .. "' to unconfigured:",
      "  " .. dir,
    }, reset_plan.listing(plan))
    -- Same state → same token; a directory gone from disk → another token.
    assert.equals(plan.token, reset_plan.plan(ws, { profile = profile }).token)
    vim.fn.delete(dir, "rf")
    local after = reset_plan.plan(ws, { profile = profile })
    assert.are_not.equal(plan.token, after.token)
    -- Cached state without a directory is still cleared (and listed so).
    assert.is_true(after.state_to_clear)
    assert.is_truthy(reset_plan.listing(after)[1]:find("no build directories on disk", 1, true))
  end)

  it("verify: equal for an unchanged plan; a directory that appeared since is CHANGED", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)
    vim.fn.delete(dir, "rf")
    local plan = reset_plan.plan(ws, { profile = profile })
    assert.same({}, plan.removal_dirs)
    assert.is_true(reset_plan.verify(ws, plan))
    vim.fn.mkdir(dir, "p")
    local ok, msg = reset_plan.verify(ws, plan)
    assert.is_false(ok)
    assert.equals(reset_plan.CHANGED, msg)
    local all = reset_plan.plan(ws, { all = true })
    assert.is_true(reset_plan.verify(ws, all))
  end)

  it("a dir outside the workspace root is never in the removal set; it is listed as not removed", function()
    local root = make_ws()
    local ws, profile = load(root)
    local outside = vim.fn.tempname():gsub("\\", "/") .. "-out"
    fake_build_dir(ws, profile, outside)
    local plan = reset_plan.plan(ws, { profile = profile })
    assert.same({}, plan.removal_dirs)
    assert.same({ outside }, plan.outside_dirs)
    assert.is_true(plan.state_to_clear)
    assert.is_false(reset_plan.is_empty(plan))
    local lines = reset_plan.listing(plan)
    assert.is_truthy(lines[1]:find("no build directory is removed", 1, true), lines[1])
    assert.is_truthy(lines[2]:find("outside the workspace", 1, true), lines[2])
    assert.equals("  " .. outside, lines[3])
    -- The token covers what was shown: a plan without the outside dir differs.
    assert.are_not.equal(plan.token, reset_plan.token(plan.scope_key, plan.lock_dirs, plan.removal_dirs))
    vim.fn.delete(outside, "rf")
  end)

  it("--all covers every unit with a build dir plus the orphans", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    local plan0 = reset_plan.plan(ws, { all = true })
    local orphan = add_orphan(ws, root, "Gone")
    local plan = reset_plan.plan(ws, { all = true })
    assert.equals("all", plan.scope)
    assert.equals("the whole workspace", plan.label)
    assert.is_true(contains(plan.removal_dirs, dir))
    assert.is_true(contains(plan.removal_dirs, orphan))
    assert.is_true(contains(plan.lock_dirs, orphan))
    assert.same({ "build/Gone" }, plan.orphans)
    assert.is_true(contains(plan.units, unit))
    assert.are_not.equal(plan0.token, plan.token, "a new orphan changes the plan")
  end)
end)

describe("reset_plan.execute stop between entries", function()
  it("a stop before the removal removes nothing and leaves the unit unknown", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    local plan = reset_plan.plan(ws, { profile = profile })
    local done, got = false, nil
    reset_plan.execute(ws, plan, { stop = function() return true end, verify_ms = 200 },
      function(code, msg, stopped) done, got = true, { code = code, msg = msg, stopped = stopped } end)
    assert.is_true(vim.wait(5000, function() return done end, 20))
    assert.is_true(got.stopped)
    assert.is_not_nil(uv.fs_stat(dir), "a stopped reset removes nothing more")
    assert.equals("unknown", unit.state_value, "never reset after a stopped removal")
  end)

  it("--all stops between orphans: the next one is kept, unknown in the cache", function()
    local root = make_ws()
    local ws = load(root)
    local first = add_orphan(ws, root, "A")
    local second, second_bd = add_orphan(ws, root, "B")
    local plan = reset_plan.plan(ws, { all = true })
    -- Stop once the first orphan is gone from disk.
    local stop = function() return uv.fs_stat(first) == nil end
    local done, got = false, nil
    reset_plan.execute(ws, plan, { stop = stop, verify_ms = 200 },
      function(code, msg, stopped) done, got = true, { code = code, msg = msg, stopped = stopped } end)
    assert.is_true(vim.wait(5000, function() return done end, 20))
    assert.is_true(got.stopped)
    assert.is_nil(uv.fs_stat(first), "the first orphan was removed")
    assert.is_not_nil(uv.fs_stat(second), "the reset stopped before the second orphan")
    assert.is_true(contains(ws._build_dirs, second_bd), "the unfinished entry stays in the cache")
  end)

  it("an orphan whose removal fails stays in the cache as unknown", function()
    local root = make_ws()
    local ws = load(root)
    local dir, bd = add_orphan(ws, root, "Stuck")
    local io_tbl = ws._core._deps.io
    local real = io_tbl.rm_rf_async
    io_tbl.rm_rf_async = function(_, cb)
      if cb then vim.schedule(function() cb(false, "denied") end) end
      return require("loomworks.future").resolved(false)
    end
    local ok
    ws:delete_orphaned_build_dir("build/Stuck"):next(function(v) ok = v end)
    local waited = vim.wait(5000, function() return ok ~= nil end, 20)
    io_tbl.rm_rf_async = real
    assert.is_true(waited)
    assert.is_false(ok)
    assert.is_not_nil(uv.fs_stat(dir))
    assert.is_true(contains(ws._build_dirs, bd), "only a confirmed removal drops the entry")
    assert.equals("unknown", bd.state)
  end)
end)
