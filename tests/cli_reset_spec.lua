-- `lw reset` — HARD reset of build state (spec §16.30): remove a profile's
-- build directories (rm -rf) and drop its config units back to `unconfigured`,
-- KEEPING the profile (unlike the editor's delete). These specs pin the real
-- on-disk effect (the build dir is gone, state cleared, profile intact), the
-- `--all` scope (all profiles + orphaned dirs), and the confirmation gate
-- (non-interactive without `-y` refuses and removes nothing).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local uv = vim.uv or vim.loop

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

--- A temp workspace with a typescript App, a user `Debug` config, a `Dev` set
--- (App=Debug) and an active `Dev` profile.
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

--- Load the workspace the way dispatch does, returning (ws, its sole profile).
local function load(root)
  local ws = assert(cli._load_workspace(root, false))
  local profile = ws._profiles[1]
  assert(profile, "workspace has no profile")
  return ws, profile
end

--- Fake a configured build directory on disk + on the profile's config unit, so
--- there is something real for reset to remove.
local function fake_build_dir(ws, profile, dir)
  local pp = profile:projects()[1]
  local unit = assert(pp and pp._config_unit, "profile project has no config unit")
  vim.fn.mkdir(dir, "p")
  local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
  unit.build_dir_value = dir
  unit.state_value = "built"
  ws:_sync_build_dir_refs()
  return unit
end

-- Active libuv handle census (type -> count), so a guard test can assert
-- cmd_reset leaves nothing running (a lingering deletion subprocess/pipe or an
-- un-closed timer would show up here).
local function active_handles()
  local counts = {}
  uv.walk(function(h)
    local ok, active = pcall(function() return h:is_active() end)
    if not (ok and active) then return end
    local closing = false
    pcall(function() closing = h:is_closing() end)
    if closing then return end
    local t = "?"
    pcall(function() t = h:get_type() end)
    counts[t] = (counts[t] or 0) + 1
  end)
  return counts
end

describe("lw reset (on-disk)", function()
  local io_mod = require("loomworks.io")
  local real_rm_rf_async

  before_each(function()
    real_rm_rf_async = io_mod.rm_rf_async
    -- Deterministic, SYNCHRONOUS deletion in tests: really remove the tree (so
    -- on-disk assertions hold) but WITHOUT spawning `rd`/`rm`. A spawned `rd` on
    -- Windows CI can leave the directory delete-pending for many seconds (an AV
    -- scan handle), which makes the CLI's verify loop wait out that whole window
    -- and stalls the test-runner child past its budget. The production path
    -- keeps the real async rd + full verify ceiling; these tests exercise the
    -- reset LOGIC (plan -> delete -> clear -> verify -> report) without the
    -- platform's delete-pending timing. `_reset_verify_ms` is bounded as a
    -- backstop so no test can ever consume the 30s production ceiling.
    io_mod.rm_rf_async = function(dir, cb)
      vim.fn.delete(dir, "rf")
      if cb then vim.schedule(function() cb(true, nil) end) end
      return require("loomworks.future").resolved(true)
    end
    cli._reset_verify_ms = 4000
  end)

  after_each(function()
    io_mod.rm_rf_async = real_rm_rf_async
    cli._reset_verify_ms = nil
  end)

  it("removes the profile's build dir and drops the unit to unconfigured", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    assert.is_not_nil(uv.fs_stat(dir), "precondition: build dir exists")

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)

    assert.is_nil(r.exit_code, "reset should succeed: " .. r.stderr)
    assert.is_truthy(r.stdout:find("RESET OK", 1, true))
    -- The build directory is gone from disk. The CLI blocks until real on-disk
    -- absence, so this is already true on return; poll defensively regardless.
    assert.is_true(vim.wait(5000, function() return uv.fs_stat(dir) == nil end, 20),
      "build dir must be removed")
    -- The unit is back to unconfigured…
    assert.equals("unconfigured", unit:state())
    assert.is_nil(unit.build_dir_value)
    -- …but the profile itself is KEPT (reset, not delete).
    local kept = false
    for _, p in ipairs(ws._profiles) do if p.key == profile.key then kept = true end end
    assert.is_true(kept, "profile must survive reset")
    assert.is_falsy(profile._removed)
  end)

  it("lists and removes the build dir's owned LSP database mirror (spec §4.6)", function()
    local ws, profile = load(make_ws())
    -- Derive paths from the loaded root: it is canonicalized (on a Windows
    -- runner tempname() is an 8.3 short path, ws.root its long form), and the
    -- module maps a build dir to its mirror relative to ws.root.
    local root = ws.root
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)
    local mirror = root .. "/.nvim/cache/cc/App/Debug"
    vim.fn.mkdir(mirror, "p")
    local mf = assert(io.open(mirror .. "/compile_commands.json", "w")); mf:write("[]"); mf:close()
    -- The module (typescript here) owns no database: stand in a cmake-like one.
    local fake = {
      lsp_database_root = "cc",
      lsp_database_dir = require("loomworks.modules.cmake").lsp_database_dir,
    }
    ws._lsp_db_module_for = function() return fake end

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)

    assert.is_nil(r.exit_code, "reset should succeed: " .. r.stderr)
    assert.is_truthy(r.stdout:find("owned LSP database", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find(mirror, 1, true), r.stdout)
    assert.is_true(vim.wait(5000, function() return uv.fs_stat(mirror) == nil end, 20),
      "mirror must be removed with its build dir")
    assert.is_not_nil(uv.fs_stat(root .. "/.nvim/cache/cc"), "the area itself stays")
  end)

  it("--all removes every build dir including orphaned ones", function()
    local root = make_ws()
    local ws, profile = load(root)
    local prof_dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, prof_dir)

    -- An orphaned build dir: cached state that no ConfigUnit references.
    local BuildDir = require("loomworks.build_dir")
    local orphan_dir = root .. "/.nvim/build/orphan"
    vim.fn.mkdir(orphan_dir, "p")
    local of = assert(io.open(orphan_dir .. "/marker.txt", "w")); of:write("x"); of:close()
    table.insert(ws._build_dirs, BuildDir.new("build/orphan", orphan_dir, {
      state = "built", project_key = "Gone", config_key = "Gone",
      variant = "Gone", type = "typescript", build_dir = orphan_dir,
    }))
    assert.equals(1, #ws:get_orphaned_configs(), "precondition: one orphan")

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", "--all", "-y" })
    end)

    assert.is_nil(r.exit_code, "reset --all should succeed: " .. r.stderr)
    assert.is_true(vim.wait(5000, function() return uv.fs_stat(prof_dir) == nil end, 20),
      "profile build dir must be removed")
    assert.is_true(vim.wait(5000, function() return uv.fs_stat(orphan_dir) == nil end, 20),
      "orphaned build dir must be removed")
    assert.equals("unconfigured", unit:state())
  end)

  it("non-interactive without -y refuses and removes nothing", function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)

    -- Under `nvim --headless` stdin is not a tty → interactive() is false, so a
    -- reset without -y must refuse rather than delete unprompted (spec §16.30).
    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key })
    end)

    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("without confirmation", 1, true))
    assert.is_truthy(r.stderr:find("-y", 1, true))
    -- Nothing was touched.
    assert.is_not_nil(uv.fs_stat(dir), "build dir must remain")
    assert.equals("built", unit:state())
  end)

  it("a plan confirmed against the daemon's listing: not listed or asked again; a changed one refused (§19.15)",
    function()
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    local token = require("loomworks.reset_plan").plan(ws, { profile = profile }).token

    -- A token that differs (the directories changed since the listing).
    local bad = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key }, { plan = (token:sub(1, 1) == "0" and "1" or "0") .. token:sub(2) })
    end)
    assert.equals(1, bad.exit_code)
    assert.is_truthy(bad.stderr:find("the build directories to reset changed since they were listed", 1, true),
      bad.stderr)
    assert.equals("", bad.stdout)
    assert.is_not_nil(uv.fs_stat(dir), "build dir must remain")
    assert.equals("built", unit:state())

    -- The listed plan: no listing, no prompt (non-interactive, no -y), reset.
    local ok = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key }, { plan = token })
    end)
    assert.is_nil(ok.exit_code, ok.stderr)
    assert.is_nil(ok.stdout:find("Will remove", 1, true), ok.stdout)
    assert.is_truthy(ok.stdout:find("RESET OK", 1, true), ok.stdout)
    assert.is_true(vim.wait(5000, function() return uv.fs_stat(dir) == nil end, 20))
  end)

  it("nothing to reset when the profile has no build dir", function()
    local root = make_ws()
    local ws, profile = load(root)
    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)
    assert.is_nil(r.exit_code)
    assert.is_truthy(r.stdout:find("nothing to reset", 1, true))
  end)

  it("fails loudly (never reports OK) when the build dir survives the deletion", function()
    -- The CI failure: the rm subprocess reports completion but the directory is
    -- still present (a failed rm, or a delete-pending handle that never clears).
    -- The CLI must VERIFY on-disk absence and fail — not print RESET OK while a
    -- build tree survives. Simulate by stubbing the async rm to report success
    -- without deleting, and shrinking the verify budget so the test is fast.
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)

    local future = require("loomworks.future")
    ws._core._deps.io.rm_rf_async = function(_, cb)
      if cb then cb(true, nil) end -- "succeeded" but left the directory in place
      return future.resolved(true)
    end
    cli._reset_verify_ms = 300 -- don't wait the full delete-pending budget

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)
    cli._reset_verify_ms = nil

    assert.equals(1, r.exit_code)
    assert.is_falsy(r.stdout:find("RESET OK", 1, true))
    assert.is_truthy(r.stderr:find("could not be removed", 1, true))
    assert.is_not_nil(uv.fs_stat(dir), "the surviving dir is reported, not silently accepted")
  end)

  it("waits out a delete-pending dir (removal reported before it vanishes)", function()
    -- Delete-pending: the removal subprocess "exits" (on_done fires) while the
    -- directory is still on disk, and it vanishes a moment later. The verify
    -- loop must wait for genuine absence and then report success — not fail.
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)
    io_mod.rm_rf_async = function(d, cb)
      vim.defer_fn(function() vim.fn.delete(d, "rf") end, 150) -- vanishes later
      if cb then vim.schedule(function() cb(true, nil) end) end -- "rd exited" now
      return require("loomworks.future").resolved(true)
    end

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_truthy(r.stdout:find("RESET OK", 1, true))
    assert.is_nil(uv.fs_stat(dir), "verify must have waited until the dir was gone")
  end)

  it("leaves no libuv handle or subprocess running after reset", function()
    -- Regression guard for the CI hang: the process must exit promptly after a
    -- reset, so cmd_reset may not leave a child process, pipe, or extra timer
    -- alive (the real-CI symptom was the runner hanging ~30s post-suite).
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    fake_build_dir(ws, profile, dir)

    local before = active_handles()
    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    -- Let any close callbacks (a released lock's heartbeat timer) settle.
    vim.wait(60, function() return false end)
    local after = active_handles()

    -- The CI symptom was the process hanging on a live handle. A lingering
    -- deletion subprocess (or its pipes) is the classic cause, so assert none
    -- outlive reset, and that no timer (e.g. an un-released lock heartbeat) was
    -- added over the pre-reset baseline.
    assert.is_nil(after.process, "no child process may outlive reset")
    assert.is_nil(after.pipe, "no pipe may outlive reset")
    assert.is_true((after.timer or 0) <= (before.timer or 0),
      string.format("reset leaked a timer (%d -> %d)", before.timer or 0, after.timer or 0))
  end)

  it("a build dir that appeared between the listing and the locks is not removed: CHANGED (§16.30)", function()
    -- The unit carries state but its dir was deleted out of band: the listing
    -- says "no build directories on disk". Before the reset holds the locks,
    -- another process (`lw build` in a second terminal) recreates the dir,
    -- finishes and releases. The reset must re-plan under its locks and refuse
    -- rather than remove a directory the user was not shown.
    local root = make_ws()
    local ws, profile = load(root)
    local dir = root .. "/.nvim/build/App/Debug"
    local unit = fake_build_dir(ws, profile, dir)
    vim.fn.delete(dir, "rf")
    assert.is_nil(uv.fs_stat(dir), "precondition: the dir is gone")

    local build_lock = require("loomworks.build_lock")
    local real_acquire = build_lock.acquire
    local appeared = false
    build_lock.acquire = function(bd, ...)
      if not appeared then
        appeared = true
        vim.fn.mkdir(dir, "p")
        local mf = assert(io.open(dir .. "/marker.txt", "w")); mf:write("x"); mf:close()
      end
      return real_acquire(bd, ...)
    end
    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)
    build_lock.acquire = real_acquire

    assert.is_true(appeared, "the lock was taken")
    assert.equals(1, r.exit_code, r.stdout .. r.stderr)
    assert.is_truthy(r.stderr:find("changed since they were listed", 1, true), r.stderr)
    assert.is_falsy(r.stdout:find("RESET OK", 1, true))
    assert.is_not_nil(uv.fs_stat(dir .. "/marker.txt"), "the unlisted dir must survive")
    assert.equals("built", unit.state_value)
  end)

  it("a build dir outside the workspace root is never listed for removal; only its state is cleared", function()
    local root = make_ws()
    local ws, profile = load(root)
    local outside = vim.fn.tempname():gsub("\\", "/") .. "-outside-build"
    local unit = fake_build_dir(ws, profile, outside)

    local plan = require("loomworks.reset_plan").plan(ws, { profile = profile })
    assert.same({}, plan.removal_dirs)
    assert.is_true(plan.state_to_clear)

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", profile.key, "-y" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    assert.is_falsy(r.stdout:find("Will remove", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("outside the workspace", 1, true), r.stdout)
    assert.is_truthy(r.stdout:find("RESET OK", 1, true), r.stdout)
    assert.is_not_nil(uv.fs_stat(outside .. "/marker.txt"), "a dir outside the root is never removed")
    assert.equals("unconfigured", unit:state())
    vim.fn.delete(outside, "rf")
  end)

  it("--all: an orphan outside the workspace root is not listed for removal; its state is cleared, reported", function()
    local root = make_ws()
    local ws = load(root)
    local BuildDir = require("loomworks.build_dir")
    local outside = vim.fn.tempname():gsub("\\", "/") .. "-outside-orphan"
    vim.fn.mkdir(outside, "p")
    local of = assert(io.open(outside .. "/marker.txt", "w")); of:write("x"); of:close()
    table.insert(ws._build_dirs, BuildDir.new("build/out", outside, {
      state = "built", project_key = "Gone", config_key = "Gone",
      variant = "Gone", type = "typescript", build_dir = outside,
    }))
    local inside = root .. "/.nvim/build/orphan"
    vim.fn.mkdir(inside, "p")
    table.insert(ws._build_dirs, BuildDir.new("build/orphan", inside, {
      state = "built", project_key = "Gone2", config_key = "Gone2",
      variant = "Gone2", type = "typescript", build_dir = inside,
    }))

    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", "--all", "-y" })
    end)
    assert.is_nil(r.exit_code, r.stderr)
    -- Listed under "Not removed", after the one dir that is removed.
    assert.is_truthy(r.stdout:find("Will remove 1 build directory", 1, true), r.stdout)
    local not_removed = r.stdout:find("Not removed", 1, true)
    assert.is_truthy(not_removed, r.stdout)
    assert.is_truthy(r.stdout:find("outside the workspace", 1, true), r.stdout)
    assert.is_truthy((r.stdout:find(outside, 1, true) or 0) > not_removed, r.stdout)
    assert.is_not_nil(uv.fs_stat(outside .. "/marker.txt"), "never removed")
    assert.is_nil(uv.fs_stat(inside), "the inside orphan is removed")
    -- Nothing is removed from disk for it; only its cached state goes (as
    -- for a unit whose dir lies outside the root), and the listing said so.
    assert.is_nil(ws:find_build_dir("build/out"))
    assert.is_nil(ws:find_build_dir("build/orphan"))
    vim.fn.delete(outside, "rf")
  end)

  it("rejects a profile argument alongside --all", function()
    local root = make_ws()
    local ws, profile = load(root)
    local r = capture(function()
      return cli.cmd_reset(ws, { "reset", "--all", profile.key })
    end)
    assert.equals(1, r.exit_code)
    assert.is_truthy(r.stderr:find("--all", 1, true))
  end)
end)
