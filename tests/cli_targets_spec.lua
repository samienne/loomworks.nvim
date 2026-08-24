-- `lw target` — listing a profile's launchable targets and its default. Covers
-- collect_targets (default marking, incomplete-when-unconfigured, showing an
-- unresolvable default from the descriptor) and resolve_profile_for_listing
-- (active-profile default, sole-profile fallback, error paths). The command
-- shell (load_workspace / persistence) is covered by profile.lua's own tests;
-- here we exercise the pure seams with hand-built domain-object shapes.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

-- Minimal fakes matching the shapes launchable_targets / collect_targets read.
local function fake_target(name)
  return { is_executable = function() return true end, display_name = function() return name end }
end

--- Build a fake profile. opts:
---   launch    = { name = {command=..} }  (command launch configs on the project)
---   targets   = { id = fake_target(...) } (parsed build targets; nil = not parsed)
---   state     = unit state string ("configured" | "unconfigured" | …)
---   parses    = true to give the module a parse_targets (build-target capable)
---   default   = { project=.., target=.. } | { project=.., launch=.. }
local function fake_profile(opts)
  opts = opts or {}
  local project = {
    key = "acme",
    launch = opts.launch,
    _module = opts.parses and { impl = { parse_targets = function() return {} end } } or nil,
  }
  local unit = {
    targets = opts.targets,       -- nil → ensure_unit_targets tries (and, with no
    build_dir = nil,              --       build_dir, gives up → no build targets)
    _project = project,
    state = function() return opts.state or "configured" end,
  }
  return {
    key = opts.key or "p1",
    _default_target_descriptor = opts.default,
    projects = function() return { { _config_unit = unit } } end,
    project = function(_, k) return k == "acme" and project or nil end,
  }
end

describe("collect_targets", function()
  it("lists launch + build targets and marks the default", function()
    local prof = fake_profile({
      launch = { serve = { command = "node" } },
      targets = { app = fake_target("app"), tests = fake_target("tests") },
      state = "configured",
      default = { project = "acme", target = "app" },
    })
    local info = cli._collect_targets({}, prof)
    assert.is_false(info.incomplete)
    local by_label, default_label = {}, nil
    for _, r in ipairs(info.rows) do
      by_label[r.label] = r.kind_label
      if r.is_default then default_label = r.label end
    end
    assert.equals("launch", by_label["acme:serve"])
    assert.equals("exe", by_label["acme:app"])
    assert.equals("exe", by_label["acme:tests"])
    assert.equals("acme:app", default_label)   -- the default build target
  end)

  it("flags the list incomplete and names the project when unconfigured", function()
    local prof = fake_profile({
      launch = { serve = { command = "node" } },
      targets = nil,            -- not parsed
      parses = true,            -- module CAN produce build targets
      state = "unconfigured",   -- …but the project isn't configured
    })
    local info = cli._collect_targets({}, prof)
    assert.is_true(info.incomplete)
    assert.same({ "acme" }, info.unconfigured)
    -- Only the launch config is listable while unconfigured.
    assert.equals(1, #info.rows)
    assert.equals("acme:serve", info.rows[1].label)
  end)

  it("shows a default that isn't enumerable, from the descriptor, marked first", function()
    local prof = fake_profile({
      targets = nil, parses = true, state = "unconfigured",
      default = { project = "acme", target = "app" }, -- build target, not yet parsed
    })
    local info = cli._collect_targets({}, prof)
    assert.is_true(info.rows[1].is_default)
    assert.equals("acme:app", info.rows[1].label)
    assert.equals("exe", info.rows[1].kind_label)
    assert.is_truthy(info.rows[1].suffix)  -- "(unresolved — build to confirm)"
  end)

  it("no default set → nothing is marked", function()
    local prof = fake_profile({
      launch = { serve = { command = "node" } }, state = "configured",
    })
    local info = cli._collect_targets({}, prof)
    for _, r in ipairs(info.rows) do assert.is_falsy(r.is_default) end
  end)
end)

describe("resolve_profile_for_listing (no name → active/sole)", function()
  local function ws(profiles, active)
    return { _profiles = profiles, _active_profile_key = active }
  end

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

  it("returns the active profile when one is set", function()
    local a, b = { key = "a" }, { key = "b" }
    local p = cli._resolve_profile_for_listing(ws({ a, b }, "b"))
    assert.equals("b", p.key)
  end)

  it("falls back to the sole profile when none is active", function()
    local a = { key = "only" }
    assert.equals("only", cli._resolve_profile_for_listing(ws({ a }, nil)).key)
  end)

  it("exits non-zero with no profiles", function()
    assert.equals(1, capture(function() cli._resolve_profile_for_listing(ws({}, nil)) end))
  end)

  it("exits non-zero when several profiles and none active", function()
    assert.equals(1, capture(function()
      cli._resolve_profile_for_listing(ws({ { key = "a" }, { key = "b" } }, nil))
    end))
  end)
end)
