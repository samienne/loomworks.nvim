local Profile = require("loomworks.profile").Profile
local ProfileProject = require("loomworks.profile").ProfileProject
local h = require("tests.helpers")

describe("Profile", function()
  local function make_profile(overrides, core_overrides)
    local core = h.make_mock_core(core_overrides)
    local data = vim.tbl_deep_extend("force", {
      configuration_set = "debug",
      tool_key = nil,
      explicit = false,
      mappings = { App = "Debug", Lib = "Debug" },
    }, overrides or {})
    return Profile.new(core, "debug", data), core
  end

  describe("new", function()
    it("sets fields from data", function()
      local p = make_profile()
      assert.equals("debug", p.key)
      assert.equals("debug", p.configuration_set)
      assert.is_false(p.explicit)
    end)

    it("stores mappings", function()
      local p = make_profile()
      assert.equals("Debug", p.mappings.App)
      assert.equals("Debug", p.mappings.Lib)
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

  describe("is_configured", function()
    it("returns false when no workspace", function()
      local p = make_profile()
      assert.is_false(p:is_configured())
    end)

    it("returns true when cached profile references configured config", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            cache = {
              profiles = {
                debug = {
                  configuration_set = "debug",
                  projects = {
                    App = { config_key = "Debug" },
                  },
                },
              },
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "configured" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.is_true(p:is_configured())
    end)

    it("returns false when cached profile exists but configs have no state", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            cache = {
              profiles = {
                debug = {
                  configuration_set = "debug",
                  projects = {
                    App = { config_key = "Debug" },
                  },
                },
              },
              projects = {
                App = {
                  configurations = {
                    Debug = { variant = "Debug" }, -- skeleton, no state
                  },
                },
              },
            },
          }
        end,
      })
      assert.is_false(p:is_configured())
    end)

    it("returns false when no cached profile matches", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            cache = {
              profiles = {
                release = {
                  configuration_set = "release",
                  projects = {
                    App = { config_key = "Release" },
                  },
                },
              },
              projects = {
                App = {
                  configurations = {
                    Release = { state = "configured" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.is_false(p:is_configured())
    end)
  end)

  describe("is_running", function()
    it("returns false when nothing running", function()
      local p = make_profile()
      assert.is_false(p:is_running())
    end)

    it("returns true when profile has running action", function()
      local p, core = make_profile()
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      assert.is_true(p:is_running())
    end)
  end)

  describe("status (aggregate)", function()
    it("returns empty for profile with no mappings", function()
      local core = h.make_mock_core()
      local p = Profile.new(core, "empty", { configuration_set = "debug" })
      local label, hl = p:status()
      assert.equals("empty", label)
      assert.equals("Comment", hl)
    end)

    it("returns unconfigured when all unconfigured", function()
      local p = make_profile()
      local label, hl = p:status()
      assert.equals("unconfigured", label)
      assert.equals("Comment", hl)
    end)

    it("returns built when all built", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = { configurations = { Debug = { state = "built" } } },
                Lib = { configurations = { Debug = { state = "built" } } },
              },
            },
          }
        end,
      })
      local label, hl = p:status()
      assert.equals("built", label)
      assert.equals("DiagnosticOk", hl)
    end)

    it("returns mixed status label", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = { configurations = { Debug = { state = "built" } } },
              },
            },
          }
        end,
      })
      local label, _ = p:status()
      -- App is built, Lib is unconfigured => mixed
      assert.matches("built", label)
      assert.matches("unconfigured", label)
    end)

    it("shows failure info", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = { configurations = { Debug = { state = "failed_build" } } },
                Lib = { configurations = { Debug = { state = "built" } } },
              },
            },
          }
        end,
      })
      local label, hl = p:status()
      assert.matches("failed", label)
      assert.equals("DiagnosticError", hl)
    end)

    it("shows running status with number first", function()
      local p, core = make_profile()
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      local label, hl = p:status()
      assert.matches("1 building", label)
      assert.equals("DiagnosticWarn", hl)
    end)

    it("shows deleting status with number first", function()
      local p, core = make_profile()
      local unit = core:get_config_unit("App", "Debug")
      unit:mark_deleting(true)
      local label, hl = p:status()
      assert.matches("1/2 deleting", label)
      assert.equals("DiagnosticError", hl)
    end)
  end)

  describe("plan_deletion", function()
    it("returns empty when no workspace", function()
      local p = make_profile()
      local plan = p:plan_deletion()
      assert.are.same({}, plan.items)
    end)

    it("returns items for each mapped project", function()
      local p = make_profile(nil, {
        get_workspace = function()
          return {
            config = { projects = { App = {}, Lib = {} } },
            cache = { projects = {} },
          }
        end,
        get_profiles = function()
          return {} -- no other profiles
        end,
      })
      -- Need to override get_profiles on core too
      local plan = p:plan_deletion()
      assert.equals(2, #plan.items)
      assert.equals("App", plan.items[1].project_key)
      assert.equals("Lib", plan.items[2].project_key)
    end)
  end)

  describe("activate / deactivate", function()
    it("activate delegates to core", function()
      local activated = nil
      local p = make_profile(nil, {
        activate_profile = function(_, key) activated = key end,
      })
      p:activate()
      assert.equals("debug", activated)
    end)

    it("deactivate delegates to core", function()
      local deactivated = nil
      local p = make_profile(nil, {
        deactivate_profile = function(_, key) deactivated = key end,
      })
      p:deactivate()
      assert.equals("debug", deactivated)
    end)
  end)
end)

describe("ProfileProject", function()
  local function make_pp(tool_key, core_overrides)
    -- Provide workspace with config so ProfileProject.new can check project type
    local default_ws = {
      config = {
        projects = {
          App = { type = "cmake", path = "App", type_config = {} },
        },
      },
      cache = { projects = {} },
    }
    local merged = vim.tbl_deep_extend("force", {
      get_workspace = function() return default_ws end,
    }, core_overrides or {})
    local core = h.make_mock_core(merged)
    local data = {
      configuration_set = "debug",
      tool_key = tool_key,
      mappings = { App = "Debug" },
    }
    local profile = Profile.new(core, "debug", data)
    return profile:project("App"), core
  end

  describe("status", function()
    it("returns unconfigured by default", function()
      local pp = make_pp(nil)
      assert.equals("unconfigured", pp:status())
    end)

    it("returns deleting when unit is marked deleting", function()
      local pp, core = make_pp(nil)
      local unit = core:get_config_unit("App", "Debug")
      unit:mark_deleting(true)
      assert.equals("deleting", pp:status())
    end)

    it("returns configuring when configure task is running", function()
      local pp, core = make_pp(nil)
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "configure")
      assert.equals("configuring", pp:status())
    end)

    it("returns building when build task is running", function()
      local pp, core = make_pp(nil)
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      assert.equals("building", pp:status())
    end)
  end)

  describe("running_action", function()
    it("returns nil when nothing running", function()
      local pp = make_pp(nil)
      assert.is_nil(pp:running_action())
    end)

    it("returns the action from the ConfigUnit", function()
      local pp, core = make_pp(nil)
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      assert.equals("build", pp:running_action())
    end)

    it("shares running state across profiles via ConfigUnit", function()
      -- Two profiles referencing the same (project_key, config_key)
      -- should see the same running state
      local core = h.make_mock_core({
        get_workspace = function()
          return {
            config = {
              projects = {
                App = { type = "cmake", path = "App", type_config = {} },
              },
            },
            cache = { projects = {} },
          }
        end,
      })
      local Profile = require("loomworks.profile").Profile
      local p1 = Profile.new(core, "debug:ninja-gcc", {
        configuration_set = "debug",
        mappings = { App = "Debug" },
      })
      local p2 = Profile.new(core, "debug:ninja-clang", {
        configuration_set = "debug",
        mappings = { App = "Debug" },
      })
      -- Start a task on the shared unit
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      -- Both profiles see it
      assert.equals("build", p1:project("App"):running_action())
      assert.equals("build", p2:project("App"):running_action())
    end)
  end)

  describe("is_deleting", function()
    it("returns false by default", function()
      local pp = make_pp(nil)
      assert.is_false(pp:is_deleting())
    end)

    it("returns true when unit is marked deleting", function()
      local pp, core = make_pp(nil)
      local unit = core:get_config_unit("App", "Debug")
      unit:mark_deleting(true)
      assert.is_true(pp:is_deleting())
    end)
  end)

  describe("cached_state", function()
    it("returns nil when no workspace", function()
      local pp = make_pp(nil)
      assert.is_nil(pp:cached_state())
    end)

    it("returns cached config when present", function()
      local pp = make_pp(nil, {
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "built", last_built = "2025-01-01" },
                  },
                },
              },
            },
          }
        end,
      })
      local cached = pp:cached_state()
      assert.is_not_nil(cached)
      assert.equals("built", cached.state)
    end)

    it("returns nil for unknown project", function()
      local pp = make_pp(nil, {
        get_workspace = function()
          return { cache = { projects = {} } }
        end,
      })
      assert.is_nil(pp:cached_state())
    end)
  end)

  describe("build_dir", function()
    it("returns nil when no cached state", function()
      local pp = make_pp(nil)
      assert.is_nil(pp:build_dir())
    end)

    it("returns build_dir from cached state", function()
      local pp = make_pp(nil, {
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "configured", build_dir = "/root/.nvim/build/App/Debug" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.equals("/root/.nvim/build/App/Debug", pp:build_dir())
    end)
  end)

end)
