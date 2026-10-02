-- Concurrent writers (spec §2.7): the editor, the CLI and older loomworks
-- versions write the same `.nvim/` state files. A save must never blindly
-- overwrite a file another process changed since this one last read it:
--   * build cache   — merged per entry (no lost build records);
--   * working copy  — refused and reloaded ("redo the change");
--   * newer schema  — never rewritten; same schema + newer writer — warn once.
--
-- The "editor" is an independent Core (its own Workspace, file tracker polling
-- effectively disabled so the test sits inside its reconciliation window); the
-- "CLI" is the CLI's own singleton core driven through cli.lua, exactly as a
-- second process would write the files.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local Core = require("loomworks.core")
local FileTracker = require("loomworks.file_tracker")
local io_mod = require("loomworks.io")
local trust = require("loomworks.trust")
local cache_mod = require("loomworks.cache")
local user_mod = require("loomworks.user")

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

--- Temp workspace: typescript App with a `Debug` config, a `Dev` set, an
--- active `Dev` profile — all authored through the CLI.
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  vim.fn.mkdir(root .. "/Lib", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  local r = capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  assert(io_mod.read_file(user_mod.filepath(root)), "make_ws: no working copy: " .. r.stderr)
  -- The CLI's singleton core stays loaded on this root with a live file
  -- tracker; stop it so a later test's edits here are not reconciled by it.
  local lc = require("loomworks")._core()
  if lc._workspace then lc._workspace:_stop_tracking() end
  return root
end

--- An editor process: its own Core over the real files. The file tracker's
--- poll is pushed out of reach so nothing reconciles behind the test's back.
local function editor(root)
  local notes = {}
  local core = Core.new({
    notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end,
    -- The CLI's core in this same test process installs `on_save_refused`
    -- (die) on the shared default deps; an editor reports instead.
    on_save_refused = false,
    FileTracker = {
      new = function(o)
        o.interval = 3600 * 1000
        return FileTracker.new(o)
      end,
    },
  })
  core:setup({ root = root })
  assert(vim.wait(15000, function() return core._state ~= "initializing" end, 10))
  return core._workspace, notes, core
end

local function has_note(notes, pat)
  for _, n in ipairs(notes) do
    if n.msg:find(pat, 1, true) then return true end
  end
  return false
end

local function read_signed(path, kind)
  local text = assert(io_mod.read_file(path))
  local status, body = trust.verify(kind, text)
  assert.equals("valid", status)
  return vim.json.decode(body), text
end

--- Give the profile's unit a configured/built build dir (as a finished build
--- leaves it) and persist it.
local function record_build(ws, state)
  local pp = ws._profiles[1]:projects()[1]
  local unit = assert(pp and pp._config_unit, "profile project has no config unit")
  local dir = ws.root .. "/.nvim/build/App/Debug"
  vim.fn.mkdir(dir, "p")
  unit.build_dir_value = dir
  unit.state_value = state or "built"
  unit.last_built = "2026-10-01T00:00:00Z"
  ws:_sync_build_dir_refs()
  return unit, dir
end

local function build_states(root)
  local data = read_signed(cache_mod.filepath(root), "cache")
  local states = {}
  for key, entry in pairs(data.build_dirs or {}) do states[key] = entry.state end
  return states, data
end

local function config_names(ws, project_key)
  local names = {}
  for _, p in pairs(ws._projects) do
    if p.key == project_key then
      for _, c in ipairs(p._configurations or {}) do names[c.name] = true end
    end
  end
  return names
end

describe("concurrent writers (spec §2.7)", function()
  -- (a) editor config edit vs a concurrent `lw configuration add`
  it("a stale working-copy save is refused and reloaded, never overwriting the other process's change", function()
    local root = make_ws()
    local ews, notes = editor(root)
    assert.is_not_nil(ews)

    -- The CLI adds a configuration while the editor is open (inside its poll window).
    local r = capture(function() cli.cmd_configuration("add", root, "App", "Release", "variant:default") end)
    assert.is_nil(r.exit_code, r.stderr)

    -- The editor now makes its own working-copy change.
    local ok, err = ews:add_project("Lib", "typescript", "Lib")

    local text = assert(io_mod.read_file(user_mod.filepath(root)))
    assert.is_truthy(text:find('"Release"', 1, true), "the CLI's configuration was overwritten")
    assert.is_falsy(ok)
    assert.is_truthy(tostring(err):find("changed on disk", 1, true))
    assert.is_truthy(has_note(notes, "changed on disk"))
    -- Reloaded: the editor now sees the CLI's change, and not its refused one.
    assert.is_true(config_names(ews, "App").Release == true)
    assert.is_falsy(text:find('"Lib"', 1, true))

    -- After the reload the editor's next change saves normally.
    local ok2 = ews:add_project("Lib", "typescript", "Lib")
    assert.is_truthy(ok2)
    local text2 = assert(io_mod.read_file(user_mod.filepath(root)))
    assert.is_truthy(text2:find('"Lib"', 1, true))
    assert.is_truthy(text2:find('"Release"', 1, true))
  end)

  -- (b) a CLI build records its result; the editor saves its (stale) cache
  -- inside the poll window
  it("a stale cache save merges per entry and keeps the other process's build record", function()
    local root = make_ws()
    local ews = editor(root)

    local cws = assert(cli._load_workspace(root, false))
    local _, dir = record_build(cws, "built")
    assert.is_true(cws:_save_cache())

    -- The editor saves its in-memory cache, which has never seen that build.
    assert.is_true(ews:_save_cache())

    local states = build_states(root)
    local found
    for key, st in pairs(states) do
      if key:find("build/App/Debug", 1, true) then found = st end
    end
    assert.equals("built", found, "the CLI's build record was lost")
    -- The editor reconciled to the merged cache: it now sees the unit built.
    local unit = ews._profiles[1]:projects()[1]._config_unit
    assert.equals("built", unit.state_value)
    assert.equals(dir, unit.build_dir_value)
  end)

  it("the cache merge keeps this process's own changed entries", function()
    local root = make_ws()
    local ews = editor(root)
    local cws = assert(cli._load_workspace(root, false))
    record_build(cws, "built")
    assert.is_true(cws:_save_cache())

    -- The editor configures the same unit (its own, newer change to that entry).
    record_build(ews, "configured")
    assert.is_true(ews:_save_cache())
    local states = build_states(root)
    local found
    for key, st in pairs(states) do
      if key:find("build/App/Debug", 1, true) then found = st end
    end
    assert.equals("configured", found)
  end)

  it("a cache another process deleted merges as empty: only this process's own changes return", function()
    local root = make_ws()
    local ews = editor(root)
    local cws = assert(cli._load_workspace(root, false))
    record_build(cws, "built")
    assert.is_true(cws:_save_cache())
    -- The editor reconciles the CLI's record, then the cache is deleted out
    -- from under it (another process reset everything).
    -- (the workspace's own path spelling: on CI the temp root is an 8.3 short path
    -- that the workspace resolves to its long form)
    ews:_on_file_changed(cache_mod.filepath(ews.root), io_mod.read_file(cache_mod.filepath(root)))
    assert.equals("built", ews._profiles[1]:projects()[1]._config_unit.state_value)
    os.remove(cache_mod.filepath(root))
    assert.is_true(ews:_save_cache())
    local states = build_states(root)
    assert.is_nil(next(states), "a deleted cache must not be resurrected")
  end)

  it("a process's own consecutive saves never trip the detector", function()
    local root = make_ws()
    local ews, notes = editor(root)
    record_build(ews, "configured")
    assert.is_true(ews:_save_cache())
    record_build(ews, "built")
    assert.is_true(ews:_save_cache())
    assert.is_truthy(ews:add_project("Lib", "typescript", "Lib"))
    local ok, err = ews:_save_user()
    assert.is_true(ok, err)
    assert.equals(0, ews._save_stats.cache_merges)
    assert.equals(0, ews._save_stats.user_refusals)
    assert.is_false(has_note(notes, "changed on disk"))
    local states = build_states(root)
    local found
    for key, st in pairs(states) do
      if key:find("build/App/Debug", 1, true) then found = st end
    end
    assert.equals("built", found)
  end)

  it("the CLI reports a refused working-copy save as `lw: …` and exits 1", function()
    local root = make_ws()
    local cws = assert(cli._load_workspace(root, false))
    -- The editor changes the working copy after the CLI read it.
    local ews = editor(root)
    assert.is_truthy(ews:add_project("Lib", "typescript", "Lib"))
    local before = assert(io_mod.read_file(user_mod.filepath(root)))

    local r = capture(function() cws:add_project("Other", "typescript", "Other") end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("lw: the working copy", 1, true), r.stderr)
    assert.equals(before, io_mod.read_file(user_mod.filepath(root)))
  end)
end)

describe("writer version stamp (spec §2.7)", function()
  local sg = require("loomworks.save_guard")
  before_each(function() sg._reset_warnings() end)

  it("stamps written_by in both files; the signed working copy still verifies and loads", function()
    local root = make_ws()
    local ews = editor(root)
    assert.is_truthy(ews:add_project("Lib", "typescript", "Lib"))
    assert.is_true(ews:_save_cache())
    local udata = read_signed(user_mod.filepath(root), "user")
    assert.equals(sg.version(), udata._meta.written_by)
    assert.equals(2, udata._meta.version)
    local cdata = read_signed(cache_mod.filepath(root), "cache")
    assert.equals(sg.version(), cdata._meta.written_by)
    assert.equals(8, cdata._meta.version)
    -- Round trip through the loaders.
    assert.is_not_nil(user_mod.load(root))
    local ews2, notes2, core2 = editor(root)
    assert.equals("initialized", core2._state)
    assert.is_not_nil(ews2)
    assert.is_false(has_note(notes2, "newer than this loomworks"))
  end)

  it("a stamp from an unknown/older writer, or none, loads without a warning", function()
    local root = make_ws()
    local data = read_signed(user_mod.filepath(root), "user")
    data._meta.written_by = nil
    assert(io_mod.write_json_signed(user_mod.filepath(root), "user", data))
    local _, notes, core = editor(root)
    assert.equals("initialized", core._state)
    assert.is_false(has_note(notes, "newer than this loomworks"))
  end)

  it("same schema, newer writer: loads and warns once per process per file", function()
    local root = make_ws()
    local data = read_signed(user_mod.filepath(root), "user")
    data._meta.written_by = "999.0.0"
    assert(io_mod.write_json_signed(user_mod.filepath(root), "user", data))
    local _, notes, core = editor(root)
    assert.equals("initialized", core._state)
    assert.is_true(has_note(notes, "written by loomworks 999.0.0, newer than this loomworks"))
    local _, notes2 = editor(root)
    assert.is_false(has_note(notes2, "newer than this loomworks"))
  end)

  it("a cache with a newer schema refuses the load and is never rewritten", function()
    local root = make_ws()
    local path = cache_mod.filepath(root)
    assert(io_mod.write_json_signed(path, "cache",
      { _meta = { version = 99, written_by = "999.0.0" }, build_dirs = {}, future = { x = 1 } }))
    local before = io_mod.read_file(path)
    local _, notes, core = editor(root)
    assert.equals("uninitialized", core._state)
    local e = core:get_setup_error()
    assert.is_truthy(e.message:find("newer than this loomworks", 1, true), e.message)
    assert.is_truthy(e.message:find("update loomworks", 1, true))
    assert.is_falsy(e.message:find("reset", 1, true))
    assert.is_true(e.newer == true)
    assert.equals(before, io_mod.read_file(path))
    assert.is_truthy(#notes > 0)
  end)

  it("a working copy with a newer schema refuses the load (no discard offered) and is never rewritten", function()
    local root = make_ws()
    local path = user_mod.filepath(root)
    local data = read_signed(path, "user")
    data._meta = { version = 3, written_by = "999.0.0" }
    assert(io_mod.write_json_signed(path, "user", data))
    local before = io_mod.read_file(path)
    local _, _, core = editor(root)
    assert.equals("uninitialized", core._state)
    local e = core:get_setup_error()
    assert.is_truthy(e.message:find("newer than this loomworks", 1, true), e.message)
    assert.is_falsy(e.message:find("delete", 1, true))
    assert.is_falsy(e.user_version_mismatch)
    assert.equals(before, io_mod.read_file(path))
  end)

  it("a newer-schema cache appearing while loaded is not reconciled and never overwritten", function()
    local root = make_ws()
    local ews, _, core = editor(root)
    local path = cache_mod.filepath(root)
    assert(io_mod.write_json_signed(path, "cache",
      { _meta = { version = 99, written_by = "999.0.0" }, build_dirs = {} }))
    local before = io_mod.read_file(path)
    -- A save from the still-live object must not overwrite it.
    record_build(ews, "built")
    assert.is_false(ews:_save_cache())
    assert.equals(before, io_mod.read_file(path))
    -- The tracker delivering the change puts the workspace in the refused state.
    ews:_on_file_changed(cache_mod.filepath(ews.root), before) -- the workspace's path spelling
    assert(vim.wait(15000, function() return core._state ~= "initializing" end, 10))
    assert.equals("uninitialized", core._state)
    assert.equals(before, io_mod.read_file(path))
  end)
end)

describe("save_guard primitives", function()
  local sg = require("loomworks.save_guard")

  it("FileTracker:mark_written records the bytes written, not a re-read", function()
    local disk = "theirs"
    local t = FileTracker.new({ callback = function() end, interval = 3600 * 1000,
      read_file = function() return disk end, schedule = function(fn) fn() end })
    local path = vim.fn.tempname():gsub("\\", "/")
    t:watch(path)
    t:mark_written(path, "ours")
    -- A foreign write that landed after ours is still seen as a change.
    assert.equals("ours", t:content(path))
    t:mark_written(path)
    assert.equals("theirs", t:content(path))
    t:stop()
  end)

  it("merge_cache: own changed entries win (incl. removal), everything else from disk", function()
    local enc = io_mod.encode_sorted
    local snapshot = sg.snapshot_cache({
      build_dirs = { a = { state = "built" }, b = { state = "configured" }, gone = { state = "built" } },
      deploy_state = { d1 = { m = 1 } },
    })
    local ours = {
      _meta = { version = 8 },
      build_dirs = { a = { state = "built" }, b = { state = "built" }, new = { state = "configured" } },
      deploy_state = { d1 = { m = 1 } },
    }
    local theirs = {
      _meta = { version = 8, written_by = "x" },
      build_dirs = { a = { state = "failed" }, gone = { state = "built" }, other = { state = "built" } },
      deploy_state = { d2 = { m = 2 } },
      future_member = { keep = true },
    }
    local merged = sg.merge_cache(ours, theirs, snapshot)
    assert.equals("failed", merged.build_dirs.a.state)      -- untouched by us → disk
    assert.equals("built", merged.build_dirs.b.state)       -- changed by us → ours
    assert.equals("configured", merged.build_dirs.new.state) -- added by us
    assert.is_nil(merged.build_dirs.gone)                   -- removed by us
    assert.equals("built", merged.build_dirs.other.state)   -- added by them
    assert.is_nil(merged.deploy_state.d1)                   -- removed by them, untouched by us
    assert.equals(2, merged.deploy_state.d2.m)
    assert.same({ keep = true }, merged.future_member)
    assert.equals(ours._meta, merged._meta)
    assert.equals(enc({ state = "built" }), snapshot.build_dirs.a)
  end)

  it("the write lock waits for a live holder, reclaims a stale one, and only releases its own", function()
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/f.json"
    local h1 = assert(sg.lock(path, { wait_ms = 50 }))
    -- A second lock attempt times out against a live holder (returns nil).
    local h2 = sg.lock(path, { wait_ms = 50 })
    assert.is_nil(h2)
    sg.unlock(h1)
    assert.is_nil((vim.uv or vim.loop).fs_stat(path .. ".lock"))
    -- A stale lockfile (crashed holder) is reclaimed.
    local fd = assert(io.open(path .. ".lock", "w")); fd:write("{}"); fd:close()
    local old = os.time() - 3600
    assert((vim.uv or vim.loop).fs_utime(path .. ".lock", old, old))
    local h3 = assert(sg.lock(path, { wait_ms = 50 }))
    -- A handle whose lock was taken over is not released over the new owner.
    local stolen = { path = h3.path, token = "someone-else" }
    sg.unlock(stolen)
    assert.is_not_nil((vim.uv or vim.loop).fs_stat(path .. ".lock"))
    sg.unlock(h3)
    assert.is_nil((vim.uv or vim.loop).fs_stat(path .. ".lock"))
  end)

  -- A reclaim can use up the whole wait (a loaded Windows runner: every file
  -- operation of the read / rename / unlink is scanned). The lock it freed is
  -- then still taken, never given up on (CI run 37007580436: line above).
  it("the write lock is taken after a reclaim that outlasted the wait", function()
    local u = vim.uv or vim.loop
    local lock_record = require("loomworks.lock_record")
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/f.json"
    local fd = assert(io.open(path .. ".lock", "w")); fd:write("{}"); fd:close()
    local old = os.time() - 3600
    assert(u.fs_utime(path .. ".lock", old, old))
    local orig = lock_record.reclaim
    lock_record.reclaim = function(...)
      u.sleep(120) -- longer than the 50 ms wait
      return orig(...)
    end
    local ok, h = pcall(sg.lock, path, { wait_ms = 50 })
    lock_record.reclaim = orig
    assert(ok, h)
    assert.is_not_nil(h)
    assert.is_not_nil(u.fs_stat(path .. ".lock"))
    sg.unlock(h)
    assert.is_nil(u.fs_stat(path .. ".lock"))
  end)
end)
