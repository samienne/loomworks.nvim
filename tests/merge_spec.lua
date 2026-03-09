local merge = require("loomworks.merge")
local workspace = require("loomworks.workspace")
local h = require("tests.helpers")

--- Assemble a workspace from helper-generated JSON.
--- Uses typescript projects by default to avoid cmake kit detection.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @return loomworks.Workspace
local function make_ws(config_overrides, user_overrides, cache_overrides)
  -- Default to typescript to avoid cmake kit detection in profile generation
  local defaults = {
    projects = { App = { typescript = {} } },
  }
  local merged = config_overrides
      and vim.tbl_deep_extend("force", defaults, config_overrides)
      or defaults
  -- Replace projects entirely if provided in overrides (avoid type key merging)
  if config_overrides and config_overrides.projects then
    merged.projects = config_overrides.projects
  end

  local ws, err = workspace.assemble(
    "/root",
    h.make_config_json(merged),
    user_overrides and h.make_user_json(user_overrides) or nil,
    cache_overrides and h.make_cache_json(cache_overrides) or nil
  )
  assert(ws, err)
  return ws
end

describe("merge", function()
  describe("profile_key", function()
    it("returns set_name when no kit_id", function()
      assert.equals("debug", merge.profile_key("debug", nil))
    end)

    it("combines set_name and kit_id", function()
      assert.equals("debug:ninja-gcc", merge.profile_key("debug", "ninja-gcc"))
    end)
  end)

  describe("parse_profile_key", function()
    it("returns just set_name for plain key", function()
      local set, kit = merge.parse_profile_key("debug")
      assert.equals("debug", set)
      assert.is_nil(kit)
    end)

    it("splits set_name and kit_id", function()
      local set, kit = merge.parse_profile_key("debug:ninja-gcc")
      assert.equals("debug", set)
      assert.equals("ninja-gcc", kit)
    end)

    it("handles kit_id with colons", function()
      local set, kit = merge.parse_profile_key("debug:ninja:extra")
      assert.equals("debug", set)
      assert.equals("ninja:extra", kit)
    end)
  end)

  describe("get_all_profiles", function()
    it("generates profiles from configuration_sets", function()
      local ws = make_ws({
        configuration_sets = {
          debug = { App = "development" },
          release = { App = "production" },
        },
      })
      local profiles = merge.get_all_profiles(ws.config)
      assert.is_not_nil(profiles.debug)
      assert.is_not_nil(profiles.release)
      assert.equals("debug", profiles.debug.configuration_set)
      assert.equals("release", profiles.release.configuration_set)
    end)

    it("returns empty when no configuration_sets", function()
      local ws = make_ws()
      local profiles = merge.get_all_profiles(ws.config)
      assert.are.same({}, profiles)
    end)

    it("marks auto-generated profiles", function()
      local ws = make_ws({
        configuration_sets = { debug = { App = "development" } },
      })
      local profiles = merge.get_all_profiles(ws.config)
      assert.is_true(profiles.debug.auto_generated)
    end)

    it("explicit profiles override auto-generated", function()
      local ws = make_ws({
        configuration_sets = { debug = { App = "development" } },
        profiles = {
          debug = { configuration_set = "debug", cmake = { kit_id = "custom" } },
        },
      })
      local profiles = merge.get_all_profiles(ws.config)
      assert.is_true(profiles.debug.explicit)
      assert.equals("custom", profiles.debug.cmake.kit_id)
    end)
  end)

  describe("merge", function()
    it("produces an ActiveSet with projects", function()
      local ws = make_ws({
        configuration_sets = { debug = { App = "development" } },
      })
      local result = merge.merge(ws)
      assert.is_not_nil(result)
      assert.is_not_nil(result.projects)
      assert.is_not_nil(result.projects.App)
    end)

    it("sets project type from config", function()
      local ws = make_ws()
      local result = merge.merge(ws)
      assert.equals("typescript", result.projects.App.type)
    end)

    it("sets status to unconfigured when no cache", function()
      local ws = make_ws(
        { configuration_sets = { debug = { App = "development" } } },
        { active_profile = "debug" }
      )
      local result = merge.merge(ws)
      assert.equals("unconfigured", result.projects.App.status)
    end)

    it("reads status from cache", function()
      local ws = make_ws(
        { configuration_sets = { debug = { App = "development" } } },
        { active_profile = "debug" },
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        }
      )
      local result = merge.merge(ws)
      assert.equals("built", result.projects.App.status)
    end)

    it("resolves active profile from user preferences", function()
      local ws = make_ws(
        { configuration_sets = { debug = { App = "development" } } },
        { active_profile = "debug" }
      )
      local result = merge.merge(ws)
      assert.equals("debug", result.name)
    end)

    it("has nil name when no active profile", function()
      local ws = make_ws({
        configuration_sets = { debug = { App = "development" } },
      })
      local result = merge.merge(ws)
      assert.is_nil(result.name)
    end)

    it("resolves configuration from active set", function()
      local ws = make_ws(
        { configuration_sets = { debug = { App = "development" } } },
        { active_profile = "debug" }
      )
      local result = merge.merge(ws)
      assert.equals("development", result.projects.App.configuration)
    end)

    it("detects orphaned projects", function()
      local ws = make_ws(
        nil,
        nil,
        {
          projects = {
            OldProject = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        }
      )
      local result = merge.merge(ws)
      assert.is_not_nil(result.projects.OldProject)
      assert.is_true(result.projects.OldProject.orphaned)
    end)

    it("marks existing projects as not orphaned", function()
      local ws = make_ws()
      local result = merge.merge(ws)
      assert.is_false(result.projects.App.orphaned)
    end)
  end)
end)
