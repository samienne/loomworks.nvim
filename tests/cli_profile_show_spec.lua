-- `lw profile show [<profile>]` — a `lw status` page narrowed to one profile
-- and only what it references. Exercises the pure, color-injectable seams:
--   * `_profile_show_rows(ws, profile, color)` — the page body lines
--   * `_scope_profile_diagnostics(diags, profile, refs)` — diagnostic scoping
--   * `_resolve_profile_for_show(ws, name)` — default = active / error paths
-- with hand-built domain-object shapes, so no workspace on disk (and no tty) is
-- needed. stdout is captured/piped in the runner, so color is forced here.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local ANSI_ACTIVE = "\27[32m" -- status_palette active (green)

-- One project-in-profile. `key`/`type`/`config`/`tool`/`state`/`build_dir`
-- shape the Projects + Tools sections; `targets`/`launch` feed collect_targets.
local function fake_pp(o)
  local project = {
    key = o.key,
    type = o.type or "cmake",
    _module = { id = o.type or "cmake", impl = {} },
    launch = o.launch,
  }
  local unit = {
    _project = project,
    targets = o.targets, -- nil → no build targets enumerated
    build_dir = nil,     -- keep ensure_unit_targets a no-op
    state = function() return o.state or "configured" end,
  }
  return {
    _project = project,
    _config_unit = unit,
    project_key = function() return o.key end,
    variant_name = function() return o.config or "Debug" end,
    tool_object = function() return o.tool end,
    status = function() return o.state or "configured" end,
    build_dir = function() return o.build_dir end,
  }
end

-- A profile + its config set. `pps` is the mapped project list; `cs_mappings`
-- is the project→configuration dict shown in the Configuration set section.
local function fake_profile(o)
  local pps = o.pps or {}
  local cs
  if o.set then
    local mappings = {}
    for _, pp in ipairs(pps) do
      mappings[pp._project] = { name = (pp.variant_name and pp:variant_name()) or "Debug" }
    end
    cs = { name = o.set, mappings = mappings }
  end
  return {
    key = o.key,
    _configuration_set_name = o.set,
    _default_target_descriptor = o.default,
    projects = function() return pps end,
    config_set = function() return cs end,
    is_valid = function() return o.valid ~= false, o.reasons or {} end,
    tool_for = function(_, mid) return (o.tools or {})[mid] end,
    default_target = function() return nil end,
  }
end

local function fake_ws(o)
  return {
    root = o.root or "/ws",
    _active_profile_key = o.active,
    _profiles = o.profiles,
    diagnostics = function() return o.diags or {} end,
  }
end

local function diag(sev, msg, key)
  return { severity = sev, source = "s", message = msg, target_fold_key = key }
end

local function join(lines) return table.concat(lines, "\n") end

describe("_scope_profile_diagnostics", function()
  local profile = { key = "P1", _configuration_set_name = "dev" }
  local refs = { app = true, lib = true }

  it("keeps the profile's own, its set's, and its mapped configs' diagnostics", function()
    local diags = {
      diag("warn", "profile self", "profile:P1"),
      diag("error", "tool compat", "profile_proj:P1:app"),
      diag("warn", "set stale", "set:dev"),
      diag("warn", "app cfg", "config:app:Debug"),
      diag("warn", "lib cfg", "config:lib:Release"),
    }
    local scoped = cli._scope_profile_diagnostics(diags, profile, refs)
    assert.equals(5, #scoped)
  end)

  it("drops other profiles, other sets, unmapped projects, and workspace-level", function()
    local diags = {
      diag("warn", "other profile", "profile:P2"),
      diag("error", "other tool compat", "profile_proj:P2:app"),
      diag("warn", "other set", "set:prod"),
      diag("warn", "unrelated proj", "config:other:Debug"),
      diag("warn", "workspace level", nil),
    }
    local scoped = cli._scope_profile_diagnostics(diags, profile, refs)
    assert.equals(0, #scoped)
  end)
end)

describe("_profile_show_rows", function()
  local function build(color)
    local app = fake_pp({ key = "app", type = "cmake", config = "Debug",
      tool = { key = "ninja-gcc-12", label = "GCC 12" }, state = "built",
      build_dir = "/ws/build/app", launch = { serve = { command = "node" } },
      targets = { app = { is_executable = function() return true end,
        display_name = function() return "app" end } } })
    local lib = fake_pp({ key = "lib", type = "cmake", config = "Debug",
      tool = { key = "ninja-gcc-12" }, state = "configured" })
    local profile = fake_profile({
      key = "dev:ninja-gcc-12", set = "dev", pps = { app, lib },
      tools = { cmake = { key = "ninja-gcc-12", label = "GCC 12" } },
      default = { project = "app", target = "app" },
    })
    local ws = fake_ws({
      active = "dev:ninja-gcc-12",
      profiles = { profile },
      diags = {
        diag("warn", "profile self diag", "profile:dev:ninja-gcc-12"),
        diag("warn", "an unrelated project", "config:other:Debug"),
      },
    })
    return cli._profile_show_rows(ws, profile, color), profile
  end

  it("renders the header, set mappings, referenced projects, tools, and targets", function()
    local lines = build(false)
    local text = join(lines)
    -- Header names the profile + its set.
    assert.is_truthy(text:find("Profile", 1, true))
    assert.is_truthy(text:find("dev:ninja-gcc-12", 1, true))
    assert.is_truthy(text:find("(set dev)", 1, true))
    -- Configuration set mappings.
    assert.is_truthy(text:find("app → Debug", 1, true))
    assert.is_truthy(text:find("lib → Debug", 1, true))
    -- Projects section: both mapped projects, with config / tool / state.
    assert.is_truthy(text:find("cfg=Debug", 1, true))
    assert.is_truthy(text:find("tool=ninja%-gcc%-12"))
    assert.is_truthy(text:find("%[built%]"))
    assert.is_truthy(text:find("/ws/build/app", 1, true)) -- build dir line
    -- Tools section.
    assert.is_truthy(text:find("Tools", 1, true))
    -- Targets section marks the default.
    assert.is_truthy(text:find("Targets", 1, true))
    assert.is_truthy(text:find("app:app", 1, true))
    -- Footer help.
    assert.is_truthy(text:find("build · lw build", 1, true))
    assert.is_truthy(text:find("switch the profile · lw profile select", 1, true))
  end)

  it("scopes diagnostics to the profile — no unrelated items leak in", function()
    local lines = build(false)
    local text = join(lines)
    assert.is_truthy(text:find("profile self diag", 1, true))   -- referenced → shown
    assert.is_nil(text:find("an unrelated project", 1, true))   -- unrelated → hidden
  end)

  it("lists ONLY the projects the set maps, not unrelated ones", function()
    -- A project the profile does not map must never appear on the page.
    local lines = build(false)
    local text = join(lines)
    assert.is_truthy(text:find("app", 1, true))
    assert.is_truthy(text:find("lib", 1, true))
    assert.is_nil(text:find("stranger", 1, true))
  end)

  it("paints the header green when the profile is active and color is on", function()
    local lines = build(true)
    local header
    for _, l in ipairs(lines) do
      if l:find("Profile", 1, true) and l:find("dev:ninja-gcc-12", 1, true) then header = l end
    end
    assert.is_truthy(header)
    assert.is_truthy(header:find(ANSI_ACTIVE, 1, true))
  end)

  it("emits no ANSI when color is off", function()
    for _, l in ipairs(build(false)) do
      assert.is_nil(l:find("\27[", 1, true))
    end
  end)
end)

describe("_resolve_profile_for_show", function()
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

  local function ws(profiles, active)
    return { _profiles = profiles, _active_profile_key = active }
  end

  it("resolves a named profile by exact key", function()
    local a, b = { key = "a" }, { key = "b" }
    assert.equals("b", cli._resolve_profile_for_show(ws({ a, b }, "a"), "b").key)
  end)

  it("defaults to the active profile when no name is given", function()
    local a, b = { key = "a" }, { key = "b" }
    assert.equals("b", cli._resolve_profile_for_show(ws({ a, b }, "b")).key)
  end)

  it("dies on an unknown named profile", function()
    assert.equals(1, capture(function()
      cli._resolve_profile_for_show(ws({ { key = "a" } }, "a"), "nope")
    end))
  end)

  it("dies when omitted with no active profile", function()
    assert.equals(1, capture(function()
      cli._resolve_profile_for_show(ws({ { key = "a" }, { key = "b" } }, nil))
    end))
  end)
end)
