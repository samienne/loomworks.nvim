-- `lw profiles` / `lw profile list` highlights the active profile with the
-- same status-palette green the `lw status` page uses. Exercises the pure,
-- color-injectable seam `_profile_list_rows(ws, color)` so no tty is needed;
-- stdout is captured/piped in the runner, so color is forced explicitly here.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local ANSI_ACTIVE = "\27[32m" -- status_palette active (green)

local function ws_with(active)
  return {
    _active_profile_key = active,
    _profiles = {
      { key = "alpha", _tool_keys = { "ninja-gcc" }, _configuration_set_name = "Debug" },
      { key = "beta", _tool_keys = { "ninja-clang" }, _configuration_set_name = "Release" },
    },
  }
end

describe("lw profiles active highlight", function()
  it("paints the active profile green when color is on, leaves others plain", function()
    local lines = cli._profile_list_rows(ws_with("alpha"), true)
    local active_line, other_line
    for _, l in ipairs(lines) do
      if l:find("alpha", 1, true) and not l:find("set=", 1, true) then active_line = l end
      if l:find("beta", 1, true) and not l:find("set=", 1, true) then other_line = other_line or l end
    end
    assert.is_truthy(active_line)
    assert.is_truthy(other_line)
    assert.is_truthy(active_line:find(ANSI_ACTIVE, 1, true)) -- active is green
    assert.is_nil(other_line:find(ANSI_ACTIVE, 1, true)) -- inactive is plain
  end)

  it("emits no ANSI when color is off (pipe/redirect)", function()
    local lines = cli._profile_list_rows(ws_with("alpha"), false)
    for _, l in ipairs(lines) do
      assert.is_nil(l:find("\27[", 1, true))
    end
  end)

  it("marks the active profile with a leading `* ` and others with spaces, "
    .. "prefixing each with its stable number in key order", function()
    local lines = cli._profile_list_rows(ws_with("beta"), false)
    local alpha_name, beta_name
    for _, l in ipairs(lines) do
      if l:find("alpha", 1, true) and not l:find("set=", 1, true) then alpha_name = l end
      if l:find("beta", 1, true) and not l:find("set=", 1, true) then beta_name = l end
    end
    -- Numbered alphabetically by key: alpha=1, beta=2 (regardless of which is active).
    assert.equals("  1  alpha", alpha_name)
    assert.equals("* 2  beta", beta_name)
  end)

  it("handles the empty case", function()
    local lines = cli._profile_list_rows({ _profiles = {} }, false)
    assert.same({ "(no profiles defined)" }, lines)
  end)
end)

describe("lw profiles help footer", function()
  local function join(lines) return table.concat(lines, "\n") end
  local function ws_one(active)
    return {
      _active_profile_key = active,
      _profiles = { { key = "alpha", _tool_keys = { "ninja-gcc" }, _configuration_set_name = "Debug" } },
    }
  end

  it("includes the show and create hints", function()
    local text = join(cli._profile_list_rows(ws_with("alpha"), false))
    assert.is_truthy(text:find("show a profile · lw profile show <profile>", 1, true))
    assert.is_truthy(text:find("create a profile · lw profile create <set> <tool>", 1, true))
  end)

  it("shows the switch hint only with more than one profile", function()
    local many = join(cli._profile_list_rows(ws_with("alpha"), false))
    assert.is_truthy(many:find("switch the profile · lw profile select", 1, true))
    local one = join(cli._profile_list_rows(ws_one("alpha"), false))
    assert.is_nil(one:find("switch the profile", 1, true))
    -- The single-profile case still carries the show + create hints.
    assert.is_truthy(one:find("lw profile show <profile>", 1, true))
    assert.is_truthy(one:find("lw profile create <set> <tool>", 1, true))
  end)

  it("emits the footer plain (no ANSI) when color is off", function()
    for _, l in ipairs(cli._profile_list_rows(ws_with("alpha"), false)) do
      assert.is_nil(l:find("\27[", 1, true))
    end
  end)

  it("hints that a number can be used in place of a name", function()
    local text = join(cli._profile_list_rows(ws_with("alpha"), false))
    assert.is_truthy(text:find("use a number from this list in place of a name", 1, true))
  end)
end)

describe("profile_numbering (stable positional numbers)", function()
  local function ws(keys, active)
    local profiles = {}
    for _, k in ipairs(keys) do profiles[#profiles + 1] = { key = k } end
    return { _profiles = profiles, _active_profile_key = active }
  end

  it("numbers profiles alphabetically by key, 1..N", function()
    local order = cli._profile_numbering(ws({ "gamma", "alpha", "beta" }))
    assert.equals("alpha", order.list[1].key)
    assert.equals("beta", order.list[2].key)
    assert.equals("gamma", order.list[3].key)
    assert.equals(1, order.number.alpha)
    assert.equals(2, order.number.beta)
    assert.equals(3, order.number.gamma)
  end)

  it("is stable regardless of which profile is active", function()
    local a = cli._profile_numbering(ws({ "gamma", "alpha", "beta" }, "gamma")).number
    local b = cli._profile_numbering(ws({ "gamma", "alpha", "beta" }, "alpha")).number
    assert.same(a, b)
  end)
end)

describe("lw profiles numbering in list rows", function()
  local function ws(keys)
    local profiles = {}
    for _, k in ipairs(keys) do
      profiles[#profiles + 1] = { key = k, _tool_keys = { "t" }, _configuration_set_name = "s" }
    end
    return { _profiles = profiles, _active_profile_key = "beta" }
  end

  it("prefixes each profile with its sequential number in key order", function()
    local lines = cli._profile_list_rows(ws({ "gamma", "alpha", "beta" }), false)
    -- Header (l1) lines only: a 2-char mark then the number digit (`^..%d`).
    -- Detail lines (`set=`) and footer hints never match this shape.
    local heads = {}
    for _, l in ipairs(lines) do
      if l:match("^..%d") then heads[#heads + 1] = l end
    end
    assert.equals("  1  alpha", heads[1])
    assert.equals("* 2  beta", heads[2])
    assert.equals("  3  gamma", heads[3])
  end)
end)

describe("lw status Profiles numbering (stable, active-first order)", function()
  local pal = cli._status_palette(false)
  local function grouped() return { by_key = {}, by_project = {} } end

  it("carries the same stable numbers even though active is listed first", function()
    local ws = {
      _active_profile_key = "beta",
      _profiles = {
        { key = "alpha", _configuration_set_name = "s" },
        { key = "beta", _configuration_set_name = "s" },
        { key = "gamma", _configuration_set_name = "s" },
      },
    }
    local numbers = cli._profile_numbering(ws).number
    -- Active-first ordering, as cmd_status builds it.
    local plist = {
      { key = "beta", _configuration_set_name = "s" },
      { key = "alpha", _configuration_set_name = "s" },
      { key = "gamma", _configuration_set_name = "s" },
    }
    local rows = cli._status_profile_rows(pal, plist, "beta", grouped(), 100, numbers)
    -- beta (active) is first but keeps number 2; alpha keeps 1, gamma keeps 3.
    assert.is_truthy(rows[1]:find("*2 ", 1, true))
    assert.is_truthy(rows[1]:find("beta", 1, true))
    assert.is_truthy(rows[2]:find(" 1 ", 1, true))
    assert.is_truthy(rows[2]:find("alpha", 1, true))
    assert.is_truthy(rows[3]:find(" 3 ", 1, true))
    assert.is_truthy(rows[3]:find("gamma", 1, true))
  end)
end)

describe("numeric profile resolution (resolve_profile)", function()
  -- die() calls os.exit; capture it so the error paths don't kill the runner.
  local function capture(fn)
    local real_exit, real_stderr = os.exit, io.stderr
    local code
    io.stderr = { write = function() end }
    os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
    pcall(fn)
    os.exit, io.stderr = real_exit, real_stderr
    return code
  end

  local function ws(keys, active)
    local profiles = {}
    for _, k in ipairs(keys) do profiles[#profiles + 1] = { key = k } end
    return { _profiles = profiles, _active_profile_key = active }
  end

  it("resolves a bare integer to the stable-sorted profile", function()
    local w = ws({ "gamma", "alpha", "beta" })
    assert.equals("alpha", cli._resolve_profile(w, "1").key)
    assert.equals("beta", cli._resolve_profile(w, "2").key)
    assert.equals("gamma", cli._resolve_profile(w, "3").key)
  end)

  it("dies with the valid range on an out-of-range number", function()
    local w = ws({ "alpha", "beta" })
    assert.equals(1, capture(function() cli._resolve_profile(w, "9") end))
    assert.equals(1, capture(function() cli._resolve_profile(w, "0") end))
  end)

  it("still resolves a name/key for non-numeric args", function()
    local w = ws({ "alpha", "beta" })
    assert.equals("alpha", cli._resolve_profile(w, "alpha").key)
  end)

  it("with no_number (the query path) rejects a number but keeps name resolution", function()
    local w = ws({ "alpha", "beta" })
    -- A number no longer indexes — it is matched as a name, which fails (keys
    -- are never bare integers), exactly as `lw profile query` behaved before.
    assert.equals(1, capture(function() cli._resolve_profile(w, "2", { no_number = true }) end))
    assert.equals("beta", cli._resolve_profile(w, "beta", { no_number = true }).key)
  end)
end)
