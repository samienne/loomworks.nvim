-- `lw reset` under CLI/editor concurrency (spec §16.30 "Concurrent editor",
-- §16.6 locking). The editor fs-polls the three config files (~2s) and
-- remerges on external change; it also holds the SAME cross-process build-dir
-- lockfile the CLI takes. These specs drive the editor side in-process — a
-- second `_load_workspace` reads the real post-reset on-disk state (core:setup
-- rebuilds the Workspace from disk every call), and the real `build_lock`
-- lockfile stands in for the editor's held lock — so no second OS process is
-- needed. They pin: (2) lock contention, (1) cache-reload to unconfigured,
-- (3) mid-deletion `unknown` not downgraded, (4) the post-reset build gate.

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
  pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

--- Temp workspace: typescript App, a `Debug` config, a `Dev` set (App=Debug),
--- an active `Dev` profile.
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(root .. "/App", "p")
  local f = assert(io.open(root .. "/loomworks.json", "w"))
  f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
  capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
  capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
  capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
  return root
end

--- Load the workspace the way dispatch does; returns (ws, its sole profile).
--- core:setup rebuilds the Workspace from disk, so a repeat call models the
--- editor remerging after its fs-poll.
local function load(root)
  local ws = assert(cli._load_workspace(root, false))
  local profile = ws._profiles[1]
  assert(profile, "workspace has no profile")
  return ws, profile
end

--- Give the profile's config unit a real, configured build dir on disk.
local function fake_build_dir(ws, profile, dir, state)
  local pp = profile:projects()[1]
  local unit = assert(pp and pp._config_unit, "profile project has no config unit")
  vim.fn.mkdir(dir, "p")
  local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
  unit.build_dir_value = dir
  unit.state_value = state or "built"
  ws:_sync_build_dir_refs()
  return unit
end

describe("lw reset — CLI/editor concurrency", function()
  -- (2) Cross-process lock: reset takes the same O_EXCL build_lock the editor's
  -- task path holds (overseer.lua:476 → build_lock.acquire). If the editor is
  -- mid-build on the dir, reset must FAIL FAST and not rm a directory in use.
  it("fails fast (never rm's) when the editor holds the build-dir lock", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)

    local build_lock = require("loomworks.build_lock")
    local held = assert(build_lock.acquire(dir, "build")) -- the "editor" is building
    local r = capture(function() return cli.cmd_reset(ws, { "reset", profile.key, "-y" }) end)
    build_lock.release(held)

    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("in use", 1, true))
    assert.is_falsy(r.stdout:find("RESET OK", 1, true))
    assert.is_not_nil(uv.fs_stat(dir), "a locked build dir must survive reset")
  end)

  -- (1) Cache reload: after reset rewrites the cache (units → unconfigured), a
  -- fresh load — the editor after its fs-poll remerge — sees `unconfigured`
  -- with no manual reload. The cache IS watched (workspace.lua:6347) and a
  -- cache-only change routes to remerge (workspace.lua:6503-6506).
  it("the editor's next load sees the reset unit as unconfigured", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)
    ws:_save_cache() -- persist the built state the editor currently sees

    local r = capture(function() return cli.cmd_reset(ws, { "reset", profile.key, "-y" }) end)
    assert.is_nil(r.exit_code, r.stderr)

    local _, profile2 = load(root) -- editor remerges from the post-reset cache
    local unit2 = profile2:projects()[1]._config_unit
    -- No cached build state survives: the editor shows it as unconfigured (a
    -- fresh load still recomputes the build-dir PATH, but carries no state).
    assert.equals("unconfigured", unit2:state())
  end)

  -- (3) Mid-deletion crash safety: reset marks the cache `unknown` BEFORE
  -- removing the dir (workspace.lua:3292). If the editor remerges in that
  -- window it reads `unknown` + a vanishing dir; the missing-dir downgrade
  -- EXEMPTS `unknown` (data_model.lua:23-28), so it is NOT reset to
  -- unconfigured — a build stays blocked (overseer.lua:617) rather than racing
  -- the deletion. This is the cross-process analogue: another process left the
  -- on-disk cache at `unknown`.
  it("does not downgrade an 'unknown' unit the CLI left mid-deletion", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    unit.state_value = "unknown" -- the crash-safe marker reset writes pre-rm
    ws:_save_cache()
    vim.fn.delete(dir, "rf") -- the dir is being / has been removed

    local _, profile2 = load(root) -- editor remerges the 'unknown' cache
    local unit2 = profile2:projects()[1]._config_unit
    assert.equals("unknown", unit2:state(),
      "an 'unknown' unit must survive a missing dir so a build stays blocked")
  end)

  -- (4) Post-reset stale window: reset finished and removed the dir, but the
  -- editor still holds an in-memory `built` unit pointing at the gone dir until
  -- its next poll. #47's build gate does a LIVE stat, so a build initiated in
  -- that window is forced to reconfigure rather than `build <gone dir>`
  -- (config_unit.lua:343-362 → overseer.lua:756).
  it("forces reconfigure for stale in-memory 'built' state after the dir is gone", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)

    local r = capture(function() return cli.cmd_reset(ws, { "reset", profile.key, "-y" }) end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_nil(uv.fs_stat(dir))

    -- Editor's not-yet-polled stale copy: still thinks it is built.
    unit.state_value = "built"
    unit.build_dir_value = dir
    assert.is_false(unit:build_dir_present(), "live stat sees the dir gone")
    assert.is_true(unit:missing_build_dir_needs_reconfigure(),
      "the build gate must force a reconfigure, not build into a deleted dir")
  end)
end)
