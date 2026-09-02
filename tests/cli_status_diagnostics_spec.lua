-- `lw status` workspace diagnostics — the top Diagnostics section, the inline
-- per-item markers grouped by target_fold_key, and the `--check` exit code.
-- All three draw from the same `Workspace:diagnostics()` shape the editor uses;
-- here we exercise the pure CLI seams (`_render_diagnostics`, `_group_diagnostics`,
-- `_inline_markers`, `_check_exit_code`) with hand-built diagnostic lists, and
-- capture io.write so the color-gating is observable.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- Run `fn` with io.write captured; returns the concatenated stdout.
local function capture(fn)
  local buf = {}
  local real_write = io.write
  io.write = function(s) buf[#buf + 1] = s end
  local ok, err = pcall(fn)
  io.write = real_write
  if not ok then error(err) end
  return table.concat(buf)
end

local function diag(sev, source, message, key)
  return { severity = sev, source = source, message = message, target_fold_key = key }
end

describe("render_diagnostics (top section)", function()
  local plain = cli._status_palette(false)
  local colored = cli._status_palette(true)

  it("renders nothing when there are no diagnostics", function()
    assert.equals("", capture(function() cli._render_diagnostics(plain, {}) end))
  end)

  it("renders a header, breakdown, and one line per diagnostic (plain)", function()
    local diags = {
      diag("error", "Profile/p1", "profile 'p1' is invalid", "profile:p1"),
      diag("warn", "Project/acme/Debug", "language drift", "config:acme:Debug"),
    }
    local out = capture(function() cli._render_diagnostics(plain, diags) end)
    assert.is_truthy(out:find("Diagnostics %(2%)", 1))
    assert.is_truthy(out:find("1 error, 1 warning", 1, true))
    assert.is_truthy(out:find("✗ ", 1, true))
    assert.is_truthy(out:find("⚠ ", 1, true))
    assert.is_truthy(out:find("[Profile/p1]", 1, true))
    assert.is_truthy(out:find("profile 'p1' is invalid", 1, true))
    -- Plain output carries no ANSI escapes.
    assert.is_nil(out:find("\27%["))
  end)

  it("omits a zero count in the breakdown", function()
    local warns_only = { diag("warn", "s", "m", "set:s1") }
    local out = capture(function() cli._render_diagnostics(plain, warns_only) end)
    assert.is_truthy(out:find("1 warning", 1, true))
    assert.is_nil(out:find("error", 1, true))
  end)

  it("pluralizes counts", function()
    local diags = {
      diag("error", "a", "m", "profile:a"),
      diag("error", "b", "m", "profile:b"),
      diag("warn", "c", "m", "set:c"),
      diag("warn", "d", "m", "set:d"),
    }
    local out = capture(function() cli._render_diagnostics(plain, diags) end)
    assert.is_truthy(out:find("2 errors, 2 warnings", 1, true))
  end)

  it("emits ANSI red for errors and yellow for warnings when color is on", function()
    local diags = {
      diag("error", "a", "boom", "profile:a"),
      diag("warn", "b", "meh", "set:b"),
    }
    local out = capture(function() cli._render_diagnostics(colored, diags) end)
    assert.is_truthy(out:find("\27%[31m")) -- red error marker
    assert.is_truthy(out:find("\27%[33m")) -- yellow warn marker
  end)
end)

describe("group_diagnostics", function()
  it("groups by exact target_fold_key and skips nil keys", function()
    local diags = {
      diag("warn", "s", "m1", "profile:p1"),
      diag("error", "s", "m2", "profile:p1"),
      diag("warn", "s", "m3", "set:s1"),
      diag("error", "s", "m4", nil), -- workspace-level: top section only
    }
    local g = cli._group_diagnostics(diags)
    assert.equals(2, #g.by_key["profile:p1"])
    assert.equals(1, #g.by_key["set:s1"])
    assert.is_nil(g.by_key["nil"])
    -- Nil-keyed entry is not grouped anywhere.
    local total = 0
    for _, list in pairs(g.by_key) do total = total + #list end
    assert.equals(3, total)
  end)

  it("attaches config:<proj>:<name> diagnostics to their project", function()
    local diags = {
      diag("warn", "Project/acme/Debug", "invalid", "config:acme:Debug"),
      diag("warn", "Project/acme/Release", "drift", "config:acme:Release"),
      diag("warn", "Project/lib/Debug", "invalid", "config:lib:Debug"),
    }
    local g = cli._group_diagnostics(diags)
    assert.equals(2, #g.by_project["acme"])
    assert.equals(1, #g.by_project["lib"])
  end)

  it("keeps a project segment even when the config name contains a colon", function()
    local g = cli._group_diagnostics({
      diag("warn", "s", "m", "config:acme:Debug:asan"),
    })
    assert.equals(1, #g.by_project["acme"])
  end)
end)

describe("inline_markers", function()
  local plain = cli._status_palette(false)

  it("returns empty string for nil/empty lists", function()
    assert.equals("", cli._inline_markers(plain, nil))
    assert.equals("", cli._inline_markers(plain, {}))
  end)

  it("returns a newline-prefixed indented marker per diagnostic (message only)", function()
    local block = cli._inline_markers(plain, {
      diag("error", "Profile/p1", "bad tool", "profile:p1"),
      diag("warn", "Profile/p1", "unused tool", "profile:p1"),
    })
    assert.equals("\n", block:sub(1, 1))
    assert.is_truthy(block:find("✗ bad tool", 1, true))
    assert.is_truthy(block:find("⚠ unused tool", 1, true))
    -- Message only — the source prefix is not repeated inline.
    assert.is_nil(block:find("Profile/p1", 1, true))
    -- Two entries → two embedded newlines.
    local _, count = block:gsub("\n", "\n")
    assert.equals(2, count)
  end)
end)

describe("check_exit_code (--check)", function()
  local diags = { diag("error", "s", "m", "profile:p1") }

  it("exits non-zero with --check and diagnostics present", function()
    assert.equals(1, cli._check_exit_code(true, diags))
  end)

  it("exits zero with --check and no diagnostics", function()
    assert.equals(0, cli._check_exit_code(true, {}))
  end)

  it("exits zero without --check even when diagnostics exist", function()
    assert.equals(0, cli._check_exit_code(false, diags))
  end)
end)
