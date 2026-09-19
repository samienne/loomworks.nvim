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

describe("lw reset (on-disk)", function()
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
