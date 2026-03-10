local Project = require("loomworks.project")
local h = require("tests.helpers")

--- Create a Project with mock core and standard data.
--- @param data_overrides? table
--- @param core_overrides? table
--- @return loomworks.Project, table core
local function make_project(data_overrides, core_overrides)
  local core = h.make_mock_core(core_overrides)
  local data = vim.tbl_deep_extend("force", {
    type = "cmake",
    path = "App",
    configuration = "Debug",
    configuration_key = "Debug",
    status = "unconfigured",
    orphaned = false,
    needs_refresh = false,
    refresh_reasons = {},
    configurations = {
      Debug = { generator = "Ninja" },
      Release = { generator = "Ninja" },
    },
    cached_configurations = {},
  }, data_overrides or {})
  return Project.new(core, "App", data), core
end

describe("Project", function()
  describe("new", function()
    it("sets fields from data", function()
      local p = make_project()
      assert.equals("App", p.key)
      assert.equals("cmake", p.type)
      assert.equals("Debug", p.configuration)
      assert.equals("unconfigured", p.status)
      assert.is_false(p.orphaned)
    end)
  end)

  describe("is_stale", function()
    it("returns false when generation matches", function()
      local p = make_project()
      assert.is_false(p:is_stale())
    end)

    it("returns true after core remerges", function()
      local p, core = make_project()
      core._generation = core._generation + 1
      assert.is_true(p:is_stale())
    end)
  end)

  describe("config_cache_key", function()
    it("returns bare name without kit", function()
      local p = make_project({ tool_key = nil })
      assert.equals("Debug", p:config_cache_key("Debug"))
    end)

    it("appends kit_id", function()
      local p = make_project({ tool_key = "ninja-gcc" })
      assert.equals("Debug:ninja-gcc", p:config_cache_key("Debug"))
    end)
  end)

  describe("running_action", function()
    it("returns nil when nothing running", function()
      local p = make_project()
      assert.is_nil(p:running_action())
    end)

    it("delegates to core", function()
      local p = make_project(nil, {
        get_project_running_action = function(_, key)
          if key == "App" then return "build" end
          return nil
        end,
      })
      assert.equals("build", p:running_action())
    end)
  end)

  describe("is_deleting_config", function()
    it("returns false by default", function()
      local p = make_project()
      assert.is_false(p:is_deleting_config("Debug"))
    end)

    it("checks via core with computed cache key", function()
      local checked = {}
      local p = make_project({ tool_key = "ninja-gcc" }, {
        is_deleting = function(_, proj, key)
          checked.proj = proj
          checked.key = key
          return true
        end,
      })
      assert.is_true(p:is_deleting_config("Debug"))
      assert.equals("App", checked.proj)
      assert.equals("Debug:ninja-gcc", checked.key)
    end)
  end)

  describe("config_running_action", function()
    it("delegates to core with computed cache key", function()
      local p = make_project({ tool_key = "ninja-gcc" }, {
        get_running_action = function(_, proj, key)
          if proj == "App" and key == "Debug:ninja-gcc" then return "configure" end
          return nil
        end,
      })
      assert.equals("configure", p:config_running_action("Debug"))
    end)
  end)

  describe("cached_config", function()
    it("returns nil when no cached configurations", function()
      local p = make_project({ cached_configurations = {} })
      assert.is_nil(p:cached_config("Debug"))
    end)

    it("returns cached config by name", function()
      local p = make_project({
        cached_configurations = {
          Debug = { state = "built", last_built = "2025-01-01" },
        },
      })
      local cached = p:cached_config("Debug")
      assert.is_not_nil(cached)
      assert.equals("built", cached.state)
    end)

    it("tries kit-qualified key first", function()
      local p = make_project({
        tool_key = "ninja-gcc",
        cached_configurations = {
          Debug = { state = "configured" },
          ["Debug:ninja-gcc"] = { state = "built" },
        },
      })
      local cached = p:cached_config("Debug")
      assert.equals("built", cached.state)
    end)

    it("falls back to bare name when kit-qualified not found", function()
      local p = make_project({
        tool_key = "ninja-gcc",
        cached_configurations = {
          Debug = { state = "configured" },
        },
      })
      local cached = p:cached_config("Debug")
      assert.equals("configured", cached.state)
    end)
  end)

  describe("to_module_context", function()
    it("builds module context with correct fields", function()
      local p = make_project({
        configuration_key = "Debug:ninja-gcc",
        tool_data = { generator = "Ninja", env = { CC = "gcc" } },
      })
      local ctx = p:to_module_context("/workspace")
      assert.equals("App", ctx.name)
      assert.equals("App", ctx.path)
      assert.equals("cmake", ctx.type)
      assert.equals("Debug", ctx.configuration)
      assert.equals("Debug:ninja-gcc", ctx.configuration_key)
      assert.equals("/workspace", ctx.workspace_root)
      assert.equals("gcc", ctx.env.CC)
    end)

    it("uses empty env when no tool_data", function()
      local p = make_project({ tool_data = nil })
      local ctx = p:to_module_context("/workspace")
      assert.are.same({}, ctx.env)
    end)
  end)

  describe("abs_path", function()
    it("combines workspace root and project path", function()
      local p = make_project(nil, {
        get_workspace = function()
          return { root = "/workspace" }
        end,
      })
      assert.equals("/workspace/App", p:abs_path())
    end)

    it("falls back to path when no workspace", function()
      local p = make_project()
      -- default mock returns nil for get_workspace
      assert.equals("App", p:abs_path())
    end)

    it("uses key when no path", function()
      local p = make_project({ path = nil }, {
        get_workspace = function()
          return { root = "/workspace" }
        end,
      })
      assert.equals("/workspace/App", p:abs_path())
    end)
  end)

  describe("__tostring", function()
    it("includes project key", function()
      local p = make_project()
      assert.matches("App", tostring(p))
    end)
  end)
end)
