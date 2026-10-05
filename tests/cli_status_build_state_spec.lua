-- `lw status` shows each profile's build state (spec §16.18): the editor's
-- aggregate profile status (`Profile:status()`, spec/ui.md §1.5) in
-- parentheses after the profile name, colored like the editor's highlight on a
-- terminal. Before, the row
-- was `*1 Dev set=Dev` both before and after a build or clean, so a CLI user
-- or agent could not tell whether the operation took effect. A task the
-- workspace daemon runs shows its profile running (spec §19.6, §19.16).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local running = require("loomworks.daemon.running")

local function quiet(fn)
  local rw, rs = io.write, io.stderr
  io.write = function() end
  io.stderr = { write = function() end }
  local ok, err = pcall(fn)
  io.write, io.stderr = rw, rs
  if not ok then error(err, 0) end
end

local function capture(fn)
  local buf = {}
  local rw, rs = io.write, io.stderr
  io.write = function(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
  io.stderr = { write = function() end }
  local ok, err = pcall(fn)
  io.write, io.stderr = rw, rs
  if not ok then error(err, 0) end
  return table.concat(buf)
end

--- A shell App with Debug + Release (no clean_cmd => wipe); profiles Dev
--- (App=Debug, active) and Rel (App=Release).
local function make_ws()
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root .. "/App", "p")
  local lw = { projects = { App = { shell = {
    build_dir = "${workspace_root}/out/${configuration}",
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
  return assert(pp._config_unit, "profile project has no config unit"), pp
end

--- The Profiles-section row for profile `key`.
local function row_of(text, key)
  local in_profiles = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("^Profiles") then in_profiles = true
    elseif in_profiles and line:find("^%a") then in_profiles = false end
    if in_profiles and line:find(" " .. key .. " ", 1, true) then return line end
  end
  return nil
end

--- The parenthesized state on the Profiles-section row for profile `key`.
local function state_of(text, key)
  local line = row_of(text, key)
  if not line then return nil end
  local after = line:sub((line:find(" " .. key .. " ", 1, true)) + #key + 1)
  return after:match("^%s*%(([^)]*)%)%s*$")
end

local function status_text(root)
  return capture(function() cli.cmd_status(root, {}) end)
end

describe("lw status profile build state (spec §16.18)", function()
  local io_mod = require("loomworks.io")
  local saved_lines, real_rm_rf_async, real_rm_rf
  before_each(function()
    saved_lines = running.lines
    running.lines = function() return {} end -- no daemon
    -- Synchronous, no-subprocess removal (as cli_clean_wipe_spec does).
    real_rm_rf_async, real_rm_rf = io_mod.rm_rf_async, io_mod.rm_rf
    io_mod.rm_rf_async = function(dir, cb)
      vim.fn.delete(dir, "rf")
      if cb then vim.schedule(function() cb(true, nil) end) end
      return require("loomworks.future").resolved(true)
    end
    io_mod.rm_rf = function(dir) vim.fn.delete(dir, "rf"); return true end
  end)
  after_each(function()
    running.lines = saved_lines
    io_mod.rm_rf_async, io_mod.rm_rf = real_rm_rf_async, real_rm_rf
  end)

  it("changes from unconfigured to built, and back after a clean", function()
    local root = make_ws()
    local _, by0 = load(root)
    local dev_key, rel_key = by0.Dev.key, by0.Rel.key

    local before = status_text(root)
    -- The set is already the name's prefix (a profile key is `<set>[:tools]`),
    -- so the row carries no separate set column.
    assert.is_nil(row_of(before, dev_key):find("set=", 1, true), before)
    assert.equals("unconfigured", state_of(before, dev_key), before)
    assert.equals("unconfigured", state_of(before, rel_key), before)

    -- Record Dev as built (as a finished build persists it).
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    local dir = root .. "/out/Debug"
    vim.fn.mkdir(dir, "p")
    unit.build_dir_value = dir
    unit.state_value = "built"
    unit.last_built = os.time()
    ws:_sync_build_dir_refs()
    ws:_save_cache()

    local built = status_text(root)
    assert.equals("built", state_of(built, dev_key), built)
    assert.equals("unconfigured", state_of(built, rel_key), built)

    -- `lw clean` Dev: the next status shows it no longer built.
    local ws2 = load(root)
    quiet(function() cli.cmd_clean(ws2, dev_key) end)
    local cleaned = status_text(root)
    local s = state_of(cleaned, dev_key)
    assert.is_not_nil(s, cleaned)
    assert.are_not.equals("built", s, cleaned)
    assert.equals("unconfigured", s, cleaned)
    vim.fn.delete(root, "rf")
  end)

  it("shows `unknown` when every unit's state is unknown", function()
    local root = make_ws()
    local ws, by = load(root)
    local unit = unit_of(by.Dev)
    unit.build_dir_value = root .. "/out/Debug"
    unit.state_value = "unknown"
    ws:_save_cache()
    local text = status_text(root)
    assert.equals("unknown", state_of(text, by.Dev.key), text)
    vim.fn.delete(root, "rf")
  end)

  it("shows a profile the workspace daemon is building as running", function()
    local root = make_ws()
    local _, by = load(root)
    local _, pp = unit_of(by.Rel)
    local reply = { tasks = { {
      task_id = 7, name = "build", kind = "build", origin = "cli",
      profile = by.Rel.key, started_at = os.time(),
      units = { { project = pp:project_key(), configuration = pp:config_key() } },
    } } }
    running.lines = function() return { "  build  " .. by.Rel.key .. "  (lw)  1s" }, reply end
    local text = status_text(root)
    assert.equals("1 building", state_of(text, by.Rel.key), text)
    assert.equals("unconfigured", state_of(text, by.Dev.key), text)
    vim.fn.delete(root, "rf")
  end)
end)

describe("lw status profile state color (spec §16.18)", function()
  local R = require("loomworks.term").render
  local function grouped() return { by_key = {}, by_project = {} } end
  local function prof(key, label, hl)
    return { key = key, _configuration_set_name = key,
      status = function() return label, hl end }
  end
  local cases = {
    { "built", "DiagnosticOk", "\27[32m" },
    { "configured", "DiagnosticInfo", "\27[34m" },
    { "unconfigured", "Comment", "\27[2m" },
    { "1 failed build", "DiagnosticError", "\27[31m" },
    { "1 building", "DiagnosticWarn", "\27[33m" },
  }

  for _, c in ipairs(cases) do
    it("paints `(" .. c[1] .. ")` with " .. c[2] .. "'s color when color is on", function()
      local rows = cli._status_profile_rows(cli._status_palette(true),
        { prof("Dev", c[1], c[2]), prof("Rel", "built", "DiagnosticOk") }, "Rel", grouped(), 100)
      local out = R(rows[1])
      assert.is_truthy(out:find(c[3] .. "(" .. c[1] .. ")\27[0m", 1, true), out)
    end)
  end

  it("is plain text, label verbatim in parentheses, when color is off", function()
    local rows = cli._status_profile_rows(cli._status_palette(false),
      { prof("Dev", "1 built, 1 unconfigured", "DiagnosticInfo") }, "Dev", grouped(), 100)
    assert.is_truthy(rows[1]:find("^%*  Dev +%(1 built, 1 unconfigured%)$"), rows[1])
    assert.is_nil(rows[1]:find("\27", 1, true))
  end)
end)
