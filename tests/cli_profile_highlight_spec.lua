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
      if l:find("* alpha", 1, true) then active_line = l end
      if l:find("beta", 1, true) then other_line = other_line or l end
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

  it("marks the active profile with a leading `* ` and others with spaces", function()
    local lines = cli._profile_list_rows(ws_with("beta"), false)
    local alpha_name, beta_name
    for _, l in ipairs(lines) do
      if l:find("alpha", 1, true) and not l:find("set=", 1, true) then alpha_name = l end
      if l:find("beta", 1, true) and not l:find("set=", 1, true) then beta_name = l end
    end
    assert.equals("* beta", beta_name)
    assert.equals("  alpha", alpha_name)
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
end)
