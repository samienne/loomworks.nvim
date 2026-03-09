local Profile = require("loomworks.profile").Profile
local ProfileProject = require("loomworks.profile").ProfileProject
local h = require("tests.helpers")

describe("Profile", function()
  local function make_profile(overrides, core_overrides)
    local core = h.make_mock_core(core_overrides)
    local data = vim.tbl_deep_extend("force", {
      configuration_set = "debug",
      kit_id = nil,
      explicit = false,
      auto_generated = true,
      mappings = { App = "Debug", Lib = "Debug" },
    }, overrides or {})
    return Profile.new(core, "debug", data), core
  end

  describe("new", function()
    it("sets fields from data", function()
      local p = make_profile()
      assert.equals("debug", p.key)
      assert.equals("debug", p.configuration_set)
      assert.is_true(p.auto_generated)
      assert.is_false(p.explicit)
    end)

    it("stores mappings", function()
      local p = make_profile()
      assert.equals("Debug", p.mappings.App)
      assert.equals("Debug", p.mappings.Lib)
    end)
  end)

  describe("config_key", function()
    it("returns variant when no kit_id", function()
      local p = make_profile({ kit_id = nil })
      assert.equals("Debug", p:config_key("Debug"))
    end)

    it("appends kit_id when present", function()
      local p = make_profile({ kit_id = "ninja-gcc" })
      assert.equals("Debug:ninja-gcc", p:config_key("Debug"))
    end)
  end)

  describe("is_stale", function()
    it("returns false when generation matches", function()
      local p = make_profile()
      assert.is_false(p:is_stale())
    end)

    it("returns true when generation changes", function()
      local p, core = make_profile()
      core._generation = core._generation + 1
      assert.is_true(p:is_stale())
    end)
  end)

  describe("project", function()
    it("returns ProfileProject for known project", function()
      local p = make_profile()
      local pp = p:project("App")
      assert.is_not_nil(pp)
      assert.equals("App", pp.project_key)
      assert.equals("Debug", pp.variant)
    end)

    it("returns nil for unknown project", function()
      local p = make_profile()
      assert.is_nil(p:project("NonExistent"))
    end)
  end)

  describe("projects", function()
    it("returns sorted ProfileProjects", function()
      local p = make_profile()
      local pps = p:projects()
      assert.equals(2, #pps)
      assert.equals("App", pps[1].project_key)
      assert.equals("Lib", pps[2].project_key)
    end)

    it("returns empty when no mappings", function()
      local core = h.make_mock_core()
      local p = Profile.new(core, "empty", {
        configuration_set = "debug",
      })
      assert.are.same({}, p:projects())
    end)
  end)

  describe("__tostring", function()
    it("includes profile key", function()
      local p = make_profile()
      assert.matches("debug", tostring(p))
    end)
  end)

  describe("__eq", function()
    it("compares by key", function()
      local p1 = make_profile()
      local p2 = make_profile()
      assert.is_true(p1 == p2)
    end)
  end)
end)

describe("ProfileProject", function()
  local function make_pp(kit_id, core_overrides)
    local core = h.make_mock_core(core_overrides)
    local data = {
      configuration_set = "debug",
      kit_id = kit_id,
      mappings = { App = "Debug" },
    }
    local profile = Profile.new(core, "debug", data)
    return profile:project("App"), core
  end

  describe("config_key", function()
    it("bare variant without kit", function()
      local pp = make_pp(nil)
      assert.equals("Debug", pp.config_key)
    end)

    it("variant:kit with kit_id", function()
      local pp = make_pp("ninja-gcc")
      assert.equals("Debug:ninja-gcc", pp.config_key)
    end)
  end)

  describe("status", function()
    it("returns unconfigured by default", function()
      local pp = make_pp(nil)
      assert.equals("unconfigured", pp:status())
    end)

    it("returns deleting when core marks it", function()
      local pp = make_pp(nil, {
        is_deleting = function(_, proj, key)
          return proj == "App" and key == "Debug"
        end,
      })
      assert.equals("deleting", pp:status())
    end)

    it("returns configuring when running configure", function()
      local pp = make_pp(nil, {
        is_deleting = function() return false end,
        get_running_action = function(_, proj, key)
          if proj == "App" and key == "Debug" then return "configure" end
          return nil
        end,
      })
      assert.equals("configuring", pp:status())
    end)

    it("returns building when running build", function()
      local pp = make_pp(nil, {
        is_deleting = function() return false end,
        get_running_action = function(_, proj, key)
          if proj == "App" and key == "Debug" then return "build" end
          return nil
        end,
      })
      assert.equals("building", pp:status())
    end)
  end)

  describe("__tostring", function()
    it("includes project key and profile key", function()
      local pp = make_pp(nil)
      local s = tostring(pp)
      assert.matches("App", s)
      assert.matches("debug", s)
    end)
  end)
end)
