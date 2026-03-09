local Core = require("loomworks.core")
local h = require("tests.helpers")

--- Create a Core with mocked deps and standard test files.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @param dep_overrides? table
--- @return loomworks.Core, table deps (with _events_log)
local function make_core(config_overrides, user_overrides, cache_overrides, dep_overrides)
  local files = {
    ["loomworks.json"] = h.make_config_json(config_overrides),
  }
  if user_overrides then
    files["loomworks.user.json"] = h.make_user_json(user_overrides)
  end
  if cache_overrides then
    files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
  end

  local deps = h.make_test_deps(files, dep_overrides)
  local core = Core.new(deps)
  return core, deps
end

describe("Core", function()
  describe("setup", function()
    it("loads workspace successfully", function()
      local core = make_core()
      local ok = core:setup({ root = "/root" })
      assert.is_true(ok)
    end)

    it("populates workspace after setup", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local ws = core:get_workspace()
      assert.is_not_nil(ws)
      assert.equals("/root", ws.root)
    end)

    it("populates active_set after setup", function()
      local core = make_core({
        configuration_sets = { debug = { App = "Debug" } },
      })
      core:setup({ root = "/root" })
      local active = core:get_active_configuration_set()
      assert.is_not_nil(active)
      assert.is_not_nil(active.projects.App)
    end)

    it("fails when config file is missing", function()
      local deps = h.make_test_deps({}) -- no files
      local core = Core.new(deps)
      local ok = core:setup({ root = "/root" })
      assert.is_false(ok)
      assert.is_nil(core:get_workspace())
    end)

    it("emits workspace_changed and active_set_changed", function()
      local core, deps = make_core()
      core:setup({ root = "/root" })
      local events = deps._events_log
      local names = {}
      for _, e in ipairs(events) do
        names[#names + 1] = e.event
      end
      assert.is_not_nil(vim.tbl_contains(names, "workspace_changed"))
      assert.is_not_nil(vim.tbl_contains(names, "active_set_changed"))
    end)

    it("increments generation on setup", function()
      local core = make_core()
      local gen_before = core._generation
      core:setup({ root = "/root" })
      assert.equals(gen_before + 1, core._generation)
    end)
  end)

  describe("remerge", function()
    it("increments generation", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local gen = core._generation
      core:remerge()
      assert.equals(gen + 1, core._generation)
    end)

    it("is a no-op when no workspace", function()
      local core = make_core()
      -- Don't setup
      local gen = core._generation
      core:remerge()
      assert.equals(gen, core._generation)
    end)
  end)

  describe("activate_profile", function()
    it("sets active profile in user data", function()
      local saved = {}
      -- Use typescript to avoid cmake kit detection changing profile keys
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil, nil,
        {
          user = {
            save = function(root, data)
              saved.root = root
              saved.data = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      core:activate_profile("debug")
      assert.is_not_nil(saved.data)
      assert.equals("debug", saved.data.active_profile)
    end)

    it("remerges after activation", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      local gen = core._generation
      core:activate_profile("debug")
      assert.is_true(core._generation > gen)
    end)
  end)

  describe("running tasks", function()
    it("registers and queries running tasks", function()
      local core = make_core()
      core:setup({ root = "/root" })
      core:register_running_task({
        task_id = 42,
        project_key = "App",
        action = "build",
        configuration_key = "Debug",
      })
      assert.is_true(core:has_running_tasks())
      assert.equals("build", core:get_running_action("App", "Debug"))
      assert.equals("build", core:get_project_running_action("App"))
    end)

    it("unregisters running tasks", function()
      local core = make_core()
      core:setup({ root = "/root" })
      core:register_running_task({
        task_id = 42,
        project_key = "App",
        action = "build",
        configuration_key = "Debug",
      })
      core:unregister_running_task(42)
      assert.is_false(core:has_running_tasks())
      assert.is_nil(core:get_running_action("App", "Debug"))
    end)

    it("returns nil for non-running project", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_nil(core:get_running_action("App", "Debug"))
      assert.is_nil(core:get_project_running_action("App"))
    end)
  end)

  describe("record_task_result", function()
    it("records configure success", function()
      local saved_cache = nil
      local core = make_core(nil, nil, nil, {
        cache = {
          save = function(root, data)
            saved_cache = data
            return true
          end,
        },
      })
      core:setup({ root = "/root" })
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "Debug",
        success = true,
        build_dir = "/root/.nvim/build/App/Debug",
      })
      assert.is_not_nil(saved_cache)
      local cached = saved_cache.projects.App.configurations.Debug
      assert.equals("configured", cached.state)
      assert.is_not_nil(cached.last_configured)
      assert.equals("/root/.nvim/build/App/Debug", cached.build_dir)
    end)

    it("records build failure", function()
      local saved_cache = nil
      local core = make_core(nil, nil, nil, {
        cache = {
          save = function(root, data)
            saved_cache = data
            return true
          end,
        },
      })
      core:setup({ root = "/root" })
      core:record_task_result({
        project_key = "App",
        action = "build",
        configuration_key = "Debug",
        success = false,
      })
      assert.is_not_nil(saved_cache)
      local cached = saved_cache.projects.App.configurations.Debug
      assert.equals("failed_build", cached.state)
    end)
  end)

  describe("deletion", function()
    it("tracks deleting state", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_false(core:is_deleting("App", "Debug"))
      core._deleting["App\0Debug"] = true
      assert.is_true(core:is_deleting("App", "Debug"))
    end)

    it("has_pending_deletions reflects state", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_false(core:has_pending_deletions())
      core._deleting["App\0Debug"] = true
      assert.is_true(core:has_pending_deletions())
    end)
  end)

  describe("get_profile / get_profiles", function()
    it("returns nil for unknown profile", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      assert.is_nil(core:get_profile("nonexistent"))
    end)

    it("returns Profile object for known profile", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      local profile = core:get_profile("debug")
      assert.is_not_nil(profile)
      assert.equals("debug", profile.key)
      assert.equals("debug", profile.configuration_set)
    end)

    it("get_profiles returns all profiles", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = {
          debug = { App = "development" },
          release = { App = "production" },
        },
      })
      core:setup({ root = "/root" })
      local profiles = core:get_profiles()
      assert.is_not_nil(profiles.debug)
      assert.is_not_nil(profiles.release)
    end)
  end)

  describe("get_project / get_projects", function()
    it("returns nil when no active set", function()
      local core = make_core()
      -- Don't setup
      assert.is_nil(core:get_project("App"))
    end)

    it("returns Project for known project", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local proj = core:get_project("App")
      assert.is_not_nil(proj)
      assert.equals("App", proj.key)
      assert.equals("cmake", proj.type)
    end)

    it("get_projects returns all projects", function()
      local core = make_core({
        projects = {
          App = { cmake = {} },
          Lib = { cmake = {} },
        },
      })
      core:setup({ root = "/root" })
      local projects = core:get_projects()
      assert.is_not_nil(projects.App)
      assert.is_not_nil(projects.Lib)
    end)
  end)

  describe("project_for_buf", function()
    it("returns nil for empty buffer name", function()
      local core = make_core(nil, nil, nil, {
        buf_name = function() return "" end,
      })
      core:setup({ root = "/root" })
      local key, proj = core:project_for_buf(1)
      assert.is_nil(key)
      assert.is_nil(proj)
    end)

    it("matches buffer to project by path prefix", function()
      local function test_normalize(p) return p:gsub("\\", "/") end
      local core = make_core(nil, nil, nil, {
        buf_name = function() return "/root/App/src/main.cpp" end,
        normalize = test_normalize,
      })
      core:setup({ root = "/root" })
      local key, proj = core:project_for_buf(1)
      assert.equals("App", key)
      assert.is_not_nil(proj)
    end)
  end)
end)
