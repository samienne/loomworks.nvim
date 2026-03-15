local Core = require("loomworks.core")
local h = require("tests.helpers")

--- Find a ConfigurationSet by name from a core's registry.
--- @param core loomworks.Core
--- @param name string
--- @return loomworks.ConfigurationSet|nil
local function get_cs(core, name)
  return core._config_sets[name]
end

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

  -- Auto-derive detect_tools_async from merge.detect_tools if available
  if dep_overrides and dep_overrides.merge and dep_overrides.merge.detect_tools
      and not dep_overrides.detect_tools_async then
    local sync_detect = dep_overrides.merge.detect_tools
    dep_overrides.detect_tools_async = function(config, cache, callback)
      callback(sync_detect(config, cache))
    end
  end

  local deps = h.make_test_deps(files, dep_overrides)
  local core = Core.new(deps)
  return core, deps
end

describe("Core", function()
  describe("setup", function()
    it("loads workspace successfully", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.equals("initialized", core:state())
    end)

    it("fails when config file is missing", function()
      local deps = h.make_test_deps({}) -- no files
      local core = Core.new(deps)
      core:setup({ root = "/root" })
      assert.equals("uninitialized", core:state())
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
      -- Setup remerges twice: once on file read, once after tool detection
      assert.equals(gen_before + 2, core._generation)
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

  describe("ConfigurationSet:activate", function()
    it("materializes and activates a new profile", function()
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
      get_cs(core, "debug"):activate()
      assert.is_not_nil(saved.data)
      assert.equals("debug", saved.data.active_profile)
    end)

    it("activates existing profile without re-materializing", function()
      local cache_saves = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = {
            debug = { App = "development" },
            release = { App = "production" },
          },
        },
        nil,
        {
          -- Both profiles already materialized
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
            release = {
              configuration_set = "release",
              projects = { App = { config_key = "production" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
                production = { state = "configured" },
              },
            },
          },
        },
        {
          cache = {
            save = function(root, data)
              cache_saves[#cache_saves + 1] = vim.deepcopy(data)
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      -- Record cache state after setup (no cache writes expected from setup
      -- since both profiles are already materialized and referenced)
      local saves_after_setup = #cache_saves

      -- Activate A
      get_cs(core, "debug"):activate()
      -- Activate B
      get_cs(core, "release"):activate()
      -- Return to A
      get_cs(core, "debug"):activate()

      -- No cache writes should have happened during profile switching
      assert.equals(saves_after_setup, #cache_saves,
        "switching between materialized profiles should not write to cache")
    end)

    it("is safe without workspace", function()
      local core = make_core()
      -- No config sets exist without workspace — test that accessing nil is safe
      assert.is_nil(get_cs(core, "debug"))
    end)
  end)

  describe("running tasks", function()
    it("registers and queries via ConfigUnit", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(42, "build")
      assert.is_true(core:has_running_tasks())
      assert.equals("build", core._projects["App"]:running_action())
      assert.is_true(unit:is_running())
      assert.equals("build", unit:running_action())
    end)

    it("unregisters running tasks", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(42, "build")
      unit:unregister_task(42)
      assert.is_false(core:has_running_tasks())
      assert.is_false(unit:is_running())
    end)

    it("shares running state across profiles via ConfigUnit", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "debug")
      unit:register_task(50, "configure")
      assert.equals("configure", unit:running_action())
      assert.is_true(core:has_running_tasks())
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
    it("tracks deleting state via ConfigUnit", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      assert.is_false(unit:is_deleting())
      unit:mark_deleting(true)
      assert.is_true(unit:is_deleting())
    end)

  end)

  describe("get_profiles", function()
    it("returns nil for unknown profile key", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      assert.is_nil(core:get_profiles()["nonexistent"])
    end)

    it("returns Profile object for known profile", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = { debug = { configuration_set = "debug", projects = { App = { config_key = "development" } } } },
          projects = { App = { type = "typescript", configurations = {} } },
        }
      )
      core:setup({ root = "/root" })
      local profile = core:get_profiles()["debug"]
      assert.is_not_nil(profile)
      assert.equals("debug", profile.key)
      assert.equals("debug", profile.configuration_set)
    end)

  end)

  describe("get_projects", function()
    it("returns Project for known project", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local proj = core:get_projects()["App"]
      assert.is_not_nil(proj)
      assert.equals("App", proj.key)
      assert.equals("cmake", proj.type)
    end)

  end)

  describe("project_for_buf", function()
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

    it("picks innermost project for nested paths", function()
      local function test_normalize(p) return p:gsub("\\", "/") end
      local core = make_core({
        projects = {
          Root = { cmake = {} },
          ["Root/Sub"] = { cmake = {} },
        },
      }, nil, nil, {
        buf_name = function() return "/root/Root/Sub/src/file.cpp" end,
        normalize = test_normalize,
      })
      core:setup({ root = "/root" })
      local key = core:project_for_buf(1)
      assert.equals("Root/Sub", key)
    end)

  end)

  describe("rescan_tools", function()
    local real_merge = require("loomworks.merge")

    --- Build a merge override that replaces detect_tools but keeps merge.merge.
    local function merge_with_mock_detect(detect_fn)
      return {
        detect_tools = detect_fn,
        merge = real_merge.merge,
        module_has_keyed_tools = real_merge.module_has_keyed_tools,
        get_all_profiles = real_merge.get_all_profiles,
      }
    end

    it("updates tools_by_type from module detection", function()
      local mock_tools = {
        cmake = {
          {
            tool_data = { id = "ninja-gcc-12", display = "Ninja + GCC 12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
            tool_key = "ninja-gcc-12",
            tool_label = "Ninja + GCC 12",
          },
        },
      }
      local core = make_core(nil, nil, nil, {
        merge = merge_with_mock_detect(function() return mock_tools end),
        detect_tools_async = function(config, cache, callback) callback(mock_tools) end,
      })
      core:setup({ root = "/root" })

      core:rescan_tools()

      local tools = core:get_tools_by_type()
      assert.is_not_nil(tools.cmake)
      assert.equals(1, #tools.cmake)
      assert.equals("ninja-gcc-12", tools.cmake[1].tool_key)
      assert.equals("Ninja + GCC 12", tools.cmake[1].tool_label)
    end)

    it("does not error without workspace", function()
      local core = make_core(nil, nil, nil, {
        merge = merge_with_mock_detect(function() return {} end),
      })
      -- Do NOT call setup

      -- Should not raise
      assert.has_no.errors(function()
        core:rescan_tools()
      end)

      -- tools_by_type should remain empty
      assert.same({}, core:get_tools_by_type())
    end)
  end)

  describe("Profile:deactivate (via Core)", function()
    it("clears active profile when it matches", function()
      local saved = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        { active_profile = "debug" },
        {
          profiles = {
            debug = { configuration_set = "debug", projects = { App = { config_key = "development" } } },
          },
          projects = { App = { type = "typescript", configurations = { development = {} } } },
        },
        {
          user = {
            save = function(root, data)
              saved.data = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      core:get_profiles()["debug"]:deactivate()
      assert.is_nil(saved.data.active_profile)
    end)

    it("does nothing when profile does not match active", function()
      local save_called = false
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = {
            debug = { App = "development" },
            release = { App = "development" },
          },
        },
        { active_profile = "debug" },
        {
          profiles = {
            release = { configuration_set = "release", projects = { App = { config_key = "development" } } },
          },
          projects = { App = { type = "typescript", configurations = { development = { state = "configured" } } } },
        },
        {
          user = {
            save = function()
              save_called = true
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      save_called = false -- reset from setup
      core:get_profiles()["release"]:deactivate()
      assert.is_false(save_called)
    end)
  end)

  describe("ConfigurationSet:activate (switch set)", function()
    it("activates profile for known configuration set", function()
      local saved = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = {
            debug = { App = "development" },
            release = { App = "production" },
          },
        },
        { active_profile = "debug" },
        nil,
        {
          user = {
            save = function(root, data)
              saved.data = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      get_cs(core, "release"):activate()
      assert.equals("release", saved.data.active_profile)
    end)
  end)

  describe("_materialize_from_data", function()
    it("writes profile and skeleton configs to cache", function()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil, nil,
        {
          cache = {
            save = function(root, data)
              saved_cache = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      core:_materialize_from_data(get_cs(core, "debug"))

      assert.is_not_nil(saved_cache)
      -- Profile entry
      assert.is_not_nil(saved_cache.profiles)
      assert.is_not_nil(saved_cache.profiles.debug)
      assert.equals("debug", saved_cache.profiles.debug.configuration_set)
      assert.is_not_nil(saved_cache.profiles.debug.projects)
      assert.is_not_nil(saved_cache.profiles.debug.projects.App)
      assert.equals("development", saved_cache.profiles.debug.projects.App.config_key)
      -- Skeleton config entry
      assert.is_not_nil(saved_cache.projects.App)
      assert.is_not_nil(saved_cache.projects.App.configurations.development)
      assert.equals("development", saved_cache.projects.App.configurations.development.variant)
    end)

    it("is idempotent (no-op when already materialized)", function()
      local save_count = 0
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil, nil,
        {
          cache = {
            save = function()
              save_count = save_count + 1
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      core:_materialize_from_data(get_cs(core, "debug"))
      local count_after_first = save_count
      core:_materialize_from_data(get_cs(core, "debug"))
      assert.equals(count_after_first, save_count) -- no additional save
    end)

    it("is safe without workspace", function()
      local ConfigurationSet = require("loomworks.configuration_set")
      local core = make_core()
      -- don't setup — _materialize_from_data checks for workspace
      local dummy_cs = ConfigurationSet.new(core, "debug", {})
      core:_materialize_from_data(dummy_cs) -- should not error
    end)

    it("stores tool data when tool_entry provided", function()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { Lib = { cmake = {} } },
          configuration_sets = { debug = { Lib = "Debug" } },
        },
        nil, nil,
        {
          cache = {
            save = function(root, data)
              saved_cache = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      core:_materialize_from_data(get_cs(core, "debug"), {
        tool_key = "ninja-gcc",
        tool_data = { generator = "Ninja", compiler_id = "gcc" },
        tool_label = "Ninja GCC",
        tool_mod_type = "cmake",
      })

      assert.is_not_nil(saved_cache)
      local profile = saved_cache.profiles["debug:ninja-gcc"]
      assert.is_not_nil(profile)
      assert.equals("debug", profile.configuration_set)
      assert.equals("ninja-gcc", profile.tool_key)
      assert.equals("Ninja GCC", profile.tool_label)
      assert.equals("cmake", profile.tool_mod_type)
    end)

  end)

  describe("shutdown", function()
    it("stops file tracker", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_not_nil(core._tracker)
      core:shutdown()
      assert.is_nil(core._tracker)
    end)

    it("is safe without tracker", function()
      local core = make_core()
      core:shutdown() -- should not error
    end)
  end)

  describe("_on_file_changed", function()
    it("reloads workspace when config changes", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      local gen_before = core._generation

      -- Simulate config file change with updated content
      local new_config = h.make_config_json({
        projects = { App = { typescript = {} }, Lib = { typescript = {} } },
        configuration_sets = { debug = { App = "development", Lib = "development" } },
      })
      core:_on_file_changed("/root/loomworks.json", new_config)
      assert.is_true(core._generation > gen_before)
      -- New project should be in workspace
      assert.is_not_nil(core._workspace.config.projects.Lib)
    end)

    it("updates user data when user file changes", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      local gen_before = core._generation

      local new_user = h.make_user_json({ active_profile = "debug" })
      core:_on_file_changed("/root/.nvim/loomworks.user.json", new_user)
      assert.is_true(core._generation > gen_before)
      assert.equals("debug", core._workspace.user.active_profile)
    end)

    it("updates cache data when cache file changes", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })
      local gen_before = core._generation

      local new_cache = h.make_cache_json({
        projects = {
          App = {
            type = "typescript",
            configurations = { development = { state = "built" } },
          },
        },
      })
      core:_on_file_changed("/root/.nvim/loomworks.cache.json", new_cache)
      assert.is_true(core._generation > gen_before)
      assert.is_not_nil(core._workspace.cache.projects.App)
    end)

    it("does nothing for unrecognized path", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local gen_before = core._generation
      core:_on_file_changed("/root/some_other_file.txt", "content")
      assert.equals(gen_before, core._generation)
    end)

    it("is safe without workspace", function()
      local core = make_core()
      -- don't setup
      core:_on_file_changed("/root/loomworks.json", "{}") -- should not error
    end)

    it("notifies INFO on successful config reload", function()
      local notifications = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil, nil,
        {
          notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
          end,
        }
      )
      core:setup({ root = "/root" })
      notifications = {} -- clear setup notifications

      local new_config = h.make_config_json({
        projects = { App = { typescript = {} }, Lib = { typescript = {} } },
        configuration_sets = { debug = { App = "development", Lib = "development" } },
      })
      core:_on_file_changed("/root/loomworks.json", new_config)

      local found_info = false
      for _, n in ipairs(notifications) do
        if n.msg:match("config reloaded") and n.level == vim.log.levels.INFO then
          found_info = true
        end
      end
      assert.is_true(found_info, "should notify INFO on successful config reload")
    end)

    it("notifies WARN when config reload fails with invalid JSON", function()
      local notifications = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil, nil,
        {
          notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
          end,
        }
      )
      core:setup({ root = "/root" })
      notifications = {} -- clear setup notifications

      core:_on_file_changed("/root/loomworks.json", "not valid json {{{")

      local found_warn = false
      for _, n in ipairs(notifications) do
        if n.msg:match("config reload failed") and n.level == vim.log.levels.WARN then
          found_warn = true
        end
      end
      assert.is_true(found_warn, "should notify WARN on config reload failure")
    end)

    it("notifies WARN when config validation fails", function()
      local notifications = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil, nil,
        {
          notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
          end,
          modules = {
            get = function(mod_type)
              if mod_type == "cmake" then
                return {
                  validate = function()
                    return { valid = false, warnings = { "missing CMakeLists.txt" } }
                  end,
                }
              end
              return nil
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      notifications = {} -- clear setup notifications

      -- Change config to add a cmake project that will fail validation
      local new_config = h.make_config_json({
        projects = { BadProject = { cmake = {} } },
      })
      core:_on_file_changed("/root/loomworks.json", new_config)

      local found_warn = false
      for _, n in ipairs(notifications) do
        if n.msg:match("config reload failed") and n.level == vim.log.levels.WARN then
          found_warn = true
        end
      end
      assert.is_true(found_warn, "should notify WARN when validation fails")
    end)

    it("does not update workspace on config reload failure", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })
      local gen_before = core._generation

      core:_on_file_changed("/root/loomworks.json", "not valid json {{{")

      assert.equals(gen_before, core._generation)
      -- Original project should still be there
      assert.is_not_nil(core._workspace.config.projects.App)
    end)

    it("emits active_set_changed when user file changes", function()
      local core, deps = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      -- Clear events from setup
      for i = #deps._events_log, 1, -1 do
        table.remove(deps._events_log, i)
      end

      local new_user = h.make_user_json({ active_profile = "debug" })
      core:_on_file_changed("/root/.nvim/loomworks.user.json", new_user)

      local found = false
      for _, e in ipairs(deps._events_log) do
        if e.event == "active_set_changed" then found = true end
      end
      assert.is_true(found, "should emit active_set_changed on user file change")
    end)

    it("emits active_set_changed when cache file changes", function()
      local core, deps = make_core({
        projects = { App = { typescript = {} } },
      })
      core:setup({ root = "/root" })
      for i = #deps._events_log, 1, -1 do
        table.remove(deps._events_log, i)
      end

      local new_cache = h.make_cache_json({
        projects = {
          App = {
            type = "typescript",
            configurations = { development = { state = "configured" } },
          },
        },
      })
      core:_on_file_changed("/root/.nvim/loomworks.cache.json", new_cache)

      local found = false
      for _, e in ipairs(deps._events_log) do
        if e.event == "active_set_changed" then found = true end
      end
      assert.is_true(found, "should emit active_set_changed on cache file change")
    end)

    it("defaults user data when user file content is nil", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      }, { active_profile = "debug" })
      core:setup({ root = "/root" })
      assert.equals("debug", core._workspace.user.active_profile)

      -- Simulate user file being deleted (nil content)
      core:_on_file_changed("/root/.nvim/loomworks.user.json", nil)

      assert.is_nil(core._workspace.user.active_profile)
    end)

    it("defaults cache data when cache file content is nil", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = { development = { state = "built" } },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert.is_not_nil(core._workspace.cache.projects.App)

      -- Simulate cache file being deleted (nil content)
      core:_on_file_changed("/root/.nvim/loomworks.cache.json", nil)

      -- Cache should be reset to default (empty projects)
      assert.same({}, core._workspace.cache.projects)
    end)

    it("emits active_set_changed when config file changes", function()
      local core, deps = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      for i = #deps._events_log, 1, -1 do
        table.remove(deps._events_log, i)
      end

      local new_config = h.make_config_json({
        projects = { App = { typescript = {} } },
        configuration_sets = {
          debug = { App = "development" },
          release = { App = "production" },
        },
      })
      core:_on_file_changed("/root/loomworks.json", new_config)

      local found = false
      for _, e in ipairs(deps._events_log) do
        if e.event == "active_set_changed" then found = true end
      end
      assert.is_true(found, "should emit active_set_changed on config file change")
    end)

    it("updates configuration_sets when config changes", function()
      local core = make_core({
        projects = { App = { typescript = {} } },
        configuration_sets = { debug = { App = "development" } },
      })
      core:setup({ root = "/root" })
      assert.is_nil(core._workspace.config.configuration_sets.release)

      local new_config = h.make_config_json({
        projects = { App = { typescript = {} } },
        configuration_sets = {
          debug = { App = "development" },
          release = { App = "production" },
        },
      })
      core:_on_file_changed("/root/loomworks.json", new_config)

      assert.is_not_nil(core._workspace.config.configuration_sets.release)
      assert.equals("production", core._workspace.config.configuration_sets.release.App)
    end)
  end)

  describe("find_running_tasks_for_items", function()
    it("finds matching tasks", function()
      local core = make_core()
      core:setup({ root = "/root" })
      core:get_config_unit("App", "Debug"):register_task(1, "build")
      core:get_config_unit("Lib", "Debug"):register_task(2, "configure")

      local matches = core:find_running_tasks_for_items({
        { project_key = "App", config_key = "Debug" },
      })
      assert.is_not_nil(matches[1])
      assert.is_nil(matches[2])
    end)

  end)

  describe("stop_tasks_then", function()
    it("calls on_done immediately for empty list", function()
      local core = make_core()
      local done = false
      core:stop_tasks_then({}, function() done = true end)
      assert.is_true(done)
    end)

  end)

  describe("plan_config_deletion", function()
    it("resets config when only pinned profiles reference it", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["App/development"] = {
              mappings = { App = "development" },
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "configured", build_dir = "/root/.nvim/build/App/development" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local plan = core:get_config_unit("App", "development"):plan_deletion()
      assert.equals(1, #plan.items)
      assert.equals("App", plan.items[1].project_key)
      assert.equals("/root/.nvim/build/App/development", plan.items[1].build_dir)
      -- Pinned profile still references it, so disposition is "reset"
      assert.equals("reset", plan.items[1].disposition)
      assert.is_true(plan.defined_in_config)
    end)

    it("returns empty plan when no workspace", function()
      local core = make_core()
      -- don't setup
      local plan = core:get_config_unit("App", "Debug"):plan_deletion()
      assert.are.same({}, plan.items)
      assert.is_false(plan.defined_in_config)
    end)

    it("excludes config when a set-based profile references it", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { debug = { App = "Debug" } },
        },
        nil,
        {
          profiles = {
            ["debug:ninja-gcc"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc",
              tool_data = { generator = "Ninja", compiler_id = "gcc" },
            },
          },
          projects = {
            App = {
              type = "cmake",
              configurations = {
                ["Debug:ninja-gcc"] = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/Debug",
                  variant = "Debug",
                  tool_key = "ninja-gcc",
                },
              },
            },
          },
        },
        {
          tools_by_type = {
            cmake = {
              { tool_key = "ninja-gcc", tool_data = { generator = "Ninja", compiler_id = "gcc" }, tool_label = "Ninja GCC" },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local plan = core:get_config_unit("App", "Debug:ninja-gcc"):plan_deletion()
      -- Config is referenced by set-based profile — disposition is "reset"
      assert.equals(1, #plan.items)
      assert.equals("reset", plan.items[1].disposition)
    end)
  end)

  describe("delete_cached_configs", function()
    it("removes config from cache and saves", function()
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built", build_dir = "/root/.nvim/build/App/development" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      core:delete_cached_configs({
        { project_key = "App", config_key = "development" },
      })
      local ws = core:get_workspace()
      -- Project should be removed since no configs left
      assert.is_nil(ws.cache.projects.App)
    end)

    it("refuses to delete build dir outside workspace root", function()
      local notifications = {}
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        nil,
        {
          notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
          end,
        }
      )
      core:setup({ root = "/root" })
      assert.is_false(core:_validate_build_dir("/other/path/App", "/root"))
      local found_refusal = false
      for _, n in ipairs(notifications) do
        if n.msg:match("refusing to delete") then
          found_refusal = true
          break
        end
      end
      assert.is_true(found_refusal)
    end)

    it("refuses prefix collision (e.g. /root vs /roots)", function()
      local notifications = {}
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        nil,
        {
          notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
          end,
        }
      )
      core:setup({ root = "/root" })
      -- /roots starts with /root but is NOT under /root
      assert.is_false(core:_validate_build_dir("/roots/build/App", "/root"))
    end)

    it("allows build dir under workspace root", function()
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        nil,
        { notify = function() end }
      )
      core:setup({ root = "/root" })
      assert.is_true(core:_validate_build_dir("/root/.nvim/build/App", "/root"))
      assert.is_true(core:_validate_build_dir("/root/build/Debug", "/root"))
    end)
  end)

  describe("execute_deletion", function()
    it("marks items as deleting during execution", function()
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                dev = { state = "configured" },
              },
            },
          },
        },
        {
          cache = { save = function() return true end },
        }
      )
      core:setup({ root = "/root" })

      local plan = {
        items = {
          { project_key = "App", config_key = "dev" },
        },
      }

      local done = false
      core:execute_deletion(plan, nil, function() done = true end)
      assert.is_true(done)
      -- After completion, deleting flag should be cleared
      assert.is_false(core:get_config_unit("App", "dev"):is_deleting())
    end)

    it("removes profile from cache.profiles on profile deletion", function()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = { configuration_set = "debug" },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        },
        {
          cache = {
            save = function(root, data)
              saved_cache = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      local plan = {
        profile_key = "debug",
        items = {
          { project_key = "App", config_key = "development" },
        },
      }

      local done = false
      core:execute_deletion(plan, nil, function() done = true end)
      assert.is_true(done)
      assert.is_not_nil(saved_cache)
      -- profiles section should be cleaned up
      assert.is_true(saved_cache.profiles == nil or saved_cache.profiles.debug == nil)
    end)

    it("removes profile with no unreferenced configs (empty items)", function()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = { configuration_set = "debug" },
            release = { configuration_set = "debug" },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        },
        {
          cache = {
            save = function(root, data)
              saved_cache = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      -- Empty items = no unreferenced configs, but profile should still be removed
      local plan = {
        profile_key = "debug",
        items = {},
      }

      local done = false
      local debug_profile = core:get_profiles()["debug"]
      core:execute_deletion(plan, { deactivate_profile = debug_profile }, function() done = true end)
      assert.is_true(done)
      assert.is_not_nil(saved_cache)
      assert.is_nil(saved_cache.profiles.debug)
      assert.is_not_nil(saved_cache.profiles.release)
      -- Config preserved (no items to delete)
      assert.is_not_nil(saved_cache.projects.App.configurations.development)
    end)
  end)

  describe("find_referencing_profiles", function()
    it("finds profiles referencing a config", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["App/development"] = {
              mappings = { App = "development" },
              projects = { App = { config_key = "development" } },
            },
          },
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
      core:setup({ root = "/root" })

      local refs = core:get_config_unit("App", "development"):referencing_profiles()
      assert.equals(1, #refs)
      assert.equals("App/development", refs[1].key)
    end)

  end)

  describe("_cleanup_orphaned_skeletons", function()
    it("drops unconfigured skeleton with no profile reference", function()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {}, -- no state = unconfigured
              },
            },
          },
        },
        {
          cache = {
            save = function(root, data)
              saved_cache = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      assert.is_not_nil(saved_cache)
      -- Config should have been dropped
      assert.is_nil(saved_cache.projects)
    end)

    it("preserves configs with state (leaves them as orphans)", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          -- No profiles, but a built config exists
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
      core:setup({ root = "/root" })
      -- Config should NOT be dropped — it has state
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.projects)
      assert.is_not_nil(ws.cache.projects.App)
      assert.is_not_nil(ws.cache.projects.App.configurations.development)
      assert.equals("built", ws.cache.projects.App.configurations.development.state)
      -- No pinned profile should be created
      assert.is_nil(ws.cache.profiles)
    end)

    it("does not touch configs referenced by a profile", function()
      local saved = false
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
              },
            },
          },
        },
        {
          cache = {
            save = function()
              saved = true
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      -- No changes needed since config is already referenced
      assert.is_false(saved)
    end)
  end)

  describe("get_orphaned_configs", function()
    it("returns empty when no workspace", function()
      local core = make_core()
      assert.same({}, core:get_orphaned_configs())
    end)

    it("returns empty when all configs are referenced", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
          },
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
      core:setup({ root = "/root" })
      assert.same({}, core:get_orphaned_configs())
    end)

    it("returns configs with state not referenced by any profile", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
                production = { state = "configured" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local orphans = core:get_orphaned_configs()
      assert.equals(1, #orphans)
      assert.equals("App", orphans[1].project_key)
      assert.equals("production", orphans[1].config_key)
      assert.equals("configured", orphans[1].cached.state)
    end)

    it("excludes unconfigured skeletons", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = {}, -- unconfigured skeleton — should be dropped by cleanup
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      assert.same({}, core:get_orphaned_configs())
    end)

    it("returns sorted by project then config key", function()
      local core = make_core(
        {
          projects = {
            Bravo = { typescript = {} },
            Alpha = { typescript = {} },
          },
        },
        nil,
        {
          projects = {
            Bravo = {
              type = "typescript",
              configurations = {
                prod = { state = "built" },
              },
            },
            Alpha = {
              type = "typescript",
              configurations = {
                staging = { state = "configured" },
                dev = { state = "built" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local orphans = core:get_orphaned_configs()
      assert.equals(3, #orphans)
      assert.equals("Alpha", orphans[1].project_key)
      assert.equals("dev", orphans[1].config_key)
      assert.equals("Alpha", orphans[2].project_key)
      assert.equals("staging", orphans[2].config_key)
      assert.equals("Bravo", orphans[3].project_key)
      assert.equals("prod", orphans[3].config_key)
    end)
  end)

  describe("delete_orphaned_config", function()
    it("removes orphaned config from cache", function()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                production = { state = "built", build_dir = "/root/.nvim/build/App/production" },
              },
            },
          },
        },
        {
          cache = {
            save = function(root, data)
              saved_cache = vim.deepcopy(data)
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      assert.equals(1, #core:get_orphaned_configs())

      core:get_config_unit("App", "production"):delete()
      assert.equals(0, #core:get_orphaned_configs())
      -- Cache should no longer have the config
      assert.is_not_nil(saved_cache)
      if saved_cache.projects and saved_cache.projects.App then
        assert.is_nil(saved_cache.projects.App.configurations.production)
      end
    end)
  end)

  describe("branch switching", function()
    it("configs built on feature branch become orphaned on master", function()
      -- Simulate: master has config_set "debug" with App=Debug
      -- Feature branch added config_set "feature" and user built it
      -- Cache has profile "feature" from the feature branch
      -- After switching to master, "feature" set no longer in config
      -- The profile becomes stale (orphaned_set) but config is still referenced

      local core = make_core(
        {
          -- master: only "debug" config set
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          -- Cache from feature branch: has both profiles
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
            feature = {
              configuration_set = "feature",
              projects = { App = { config_key = "staging" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
                staging = { state = "built" },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      -- "staging" is still referenced by the cached "feature" profile
      -- so it should NOT be orphaned
      assert.same({}, core:get_orphaned_configs())

      -- The "feature" profile should still exist but with orphaned_set=true
      local profile = core:get_profiles()["feature"]
      assert.is_not_nil(profile)
      assert.is_true(profile.orphaned_set)
    end)

    it("unreferenced configs from branch switching are orphaned", function()
      -- Scenario: user built configs directly (via ConfigUnit:materialize)
      -- on feature branch, then switched to master. The configs have no
      -- profile referencing them.
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
                -- This config was built on another branch, no profile references it
                ["feature-config"] = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/feature-config",
                },
              },
            },
          },
        }
      )
      core:setup({ root = "/root" })

      local orphans = core:get_orphaned_configs()
      assert.equals(1, #orphans)
      assert.equals("App", orphans[1].project_key)
      assert.equals("feature-config", orphans[1].config_key)
      assert.equals("built", orphans[1].cached.state)
    end)

    it("deleting orphan from branch switch cleans up correctly", function()
      local deleted_dirs = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
                ["feature-config"] = {
                  state = "built",
                  build_dir = "/root/.nvim/build/App/feature-config",
                },
              },
            },
          },
        },
        {
          io = {
            rm_rf_async = function(path, cb)
              deleted_dirs[#deleted_dirs + 1] = path
              cb(true, nil)
            end,
          },
          cache = {
            save = function() return true end,
          },
        }
      )
      core:setup({ root = "/root" })
      assert.equals(1, #core:get_orphaned_configs())

      core:get_config_unit("App", "feature-config"):delete()

      -- Orphan should be gone
      assert.equals(0, #core:get_orphaned_configs())
      -- Build dir should have been deleted
      local found_dir = false
      for _, d in ipairs(deleted_dirs) do
        if d:match("feature%-config") then found_dir = true end
      end
      assert.is_true(found_dir, "build directory should be deleted")
      -- Referenced config should still exist
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.projects.App.configurations.development)
    end)

    it("round-trip: master→feature→master leaves cache intact", function()
      -- This is the A→B→A test but framed as branch switching.
      -- Master config, then feature config, then back to master.
      -- The user switches profiles (not branches) but the cache should not change.
      local cache_saves = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = {
            debug = { App = "development" },
            release = { App = "production" },
          },
        },
        nil,
        {
          profiles = {
            debug = {
              configuration_set = "debug",
              projects = { App = { config_key = "development" } },
            },
            release = {
              configuration_set = "release",
              projects = { App = { config_key = "production" } },
            },
          },
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built" },
                production = { state = "configured" },
              },
            },
          },
        },
        {
          cache = {
            save = function(root, data)
              cache_saves[#cache_saves + 1] = vim.deepcopy(data)
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      local saves_after_setup = #cache_saves

      get_cs(core, "debug"):activate()
      get_cs(core, "release"):activate()
      get_cs(core, "debug"):activate()

      assert.equals(saves_after_setup, #cache_saves,
        "switching between materialized profiles should not write to cache")
      assert.same({}, core:get_orphaned_configs())
    end)
  end)

  describe("after_deletions", function()
    it("calls fn immediately when nothing pending", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local called = false
      core:after_deletions(function() called = true end)
      assert.is_true(called)
    end)

    it("defers fn when deletions are pending", function()
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil, nil,
        { cache = { save = function() return true end } }
      )
      core:setup({ root = "/root" })
      core:get_config_unit("App", "dev"):mark_deleting(true)

      local called = false
      core:after_deletions(function() called = true end)
      assert.is_false(called)
    end)
  end)

  describe("task progress", function()
    it("stores and retrieves progress via ConfigUnit", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      unit:update_progress(1, { current = 3, total = 10 })
      local p = unit:progress()
      assert.is_not_nil(p)
      assert.equals(3, p.current)
      assert.equals(10, p.total)
    end)

    it("returns nil for non-running config", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      assert.is_nil(unit:progress())
    end)

    it("clears progress on unregister", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      unit:update_progress(1, { current = 3, total = 10 })
      unit:unregister_task(1)
      assert.is_nil(unit:progress())
    end)

    it("emits state_change on progress update", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      local fired = false
      unit:on_state_change(function() fired = true end)
      unit:update_progress(1, { current = 7, total = 10 })
      assert.is_true(fired)
    end)

    it("ignores progress when no task registered", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      -- Should not error
      unit:update_progress(999, { current = 1, total = 1 })
      assert.is_nil(unit:progress())
    end)
  end)

  describe("task elapsed time", function()
    it("tracks elapsed time via ConfigUnit", function()
      local time = 100
      local core = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      time = 142
      assert.equals(42, unit:elapsed())
    end)

    it("returns nil for non-running config", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      assert.is_nil(unit:elapsed())
    end)

    it("clears elapsed on unregister", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(1, "build")
      unit:unregister_task(1)
      assert.is_nil(unit:elapsed())
    end)
  end)

  describe("operations (on Profile)", function()
    local op_config = {
      configuration_sets = { debug = { App = "Debug" } },
    }

    local op_cache = {
      profiles = {
        debug = {
          configuration_set = "debug",
          projects = { App = { config_key = "Debug" } },
        },
      },
    }

    local function make_op_core(clock_fn)
      local time = { value = 0 }
      if not clock_fn then
        clock_fn = function() return time.value end
      end
      local core = make_core(op_config, { active_profile = "debug" }, op_cache, {
        clock = clock_fn,
      })
      core:setup({ root = "/root" })
      local profile = core:get_profiles()["debug"]
      return core, profile, time
    end

    it("tracks a running operation", function()
      local _, profile, time = make_op_core()
      time.value = 100
      profile:start_operation("build")

      local op = profile:operation()
      assert.is_not_nil(op)
      assert.equals("build", op.action)
      assert.equals(100, op.started_at)

      time.value = 130
      assert.equals(30, profile:operation_elapsed())
    end)

    it("finishes operation with success message", function()
      local _, profile, time = make_op_core()
      time.value = 100
      profile:start_operation("build")
      time.value = 190
      profile:finish_operation(true)

      local op = profile:operation()
      assert.is_not_nil(op)
      assert.equals("built in 1m30s", op.message)
      assert.is_true(op.success)
      -- No longer running
      assert.is_nil(profile:operation_elapsed())
    end)

    it("finishes operation with failure message", function()
      local _, profile, time = make_op_core()
      profile:start_operation("configure")
      time.value = 45
      profile:finish_operation(false)

      local op = profile:operation()
      assert.equals("configure failed in 45s", op.message)
      assert.is_false(op.success)
    end)

    it("configure+build operation uses generic verb", function()
      local _, profile, time = make_op_core()
      profile:start_operation("configure+build")
      time.value = 120
      profile:finish_operation(true)

      assert.equals("built in 2m00s", profile:operation().message)
    end)

    it("new operation replaces previous result", function()
      local _, profile, time = make_op_core()
      profile:start_operation("build")
      time.value = 10
      profile:finish_operation(true)
      assert.is_not_nil(profile:operation().message)

      profile:start_operation("build")
      -- Previous result replaced by running state
      assert.is_not_nil(profile:operation().started_at)
      assert.is_nil(profile:operation().message)
    end)

    it("returns nil before any operation", function()
      local _, profile = make_op_core()
      assert.is_nil(profile:operation())
      assert.is_nil(profile:operation_elapsed())
    end)

    it("emits operation events", function()
      local core, profile, time = make_op_core()
      profile:start_operation("build")
      time.value = 10
      profile:finish_operation(true)

      local events = core._deps._events_log
      local found_started, found_finished = false, false
      for _, e in ipairs(events) do
        if e.event == "operation_started" then
          assert.equals("debug", e.data.profile_key)
          found_started = true
        end
        if e.event == "operation_finished" then
          assert.equals("debug", e.data.profile_key)
          assert.is_true(e.data.success)
          found_finished = true
        end
      end
      assert.is_true(found_started)
      assert.is_true(found_finished)
    end)
  end)

  describe("record_task_result state machine", function()
    local function make_recording_core()
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        { active_profile = "debug" },
        nil,
        {
          cache = {
            save = function(root, data)
              saved_cache = data
              return true
            end,
          },
        }
      )
      core:setup({ root = "/root" })
      return core, function() return saved_cache end
    end

    it("configure success → configured", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "development",
        success = true,
      })
      assert.equals("configured", get_cache().projects.App.configurations.development.state)
    end)

    it("configure failure → failed_configure", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "development",
        success = false,
      })
      assert.equals("failed_configure", get_cache().projects.App.configurations.development.state)
    end)

    it("build success → built", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "build",
        configuration_key = "development",
        success = true,
      })
      assert.equals("built", get_cache().projects.App.configurations.development.state)
    end)

    it("build failure → failed_build", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "build",
        configuration_key = "development",
        success = false,
      })
      assert.equals("failed_build", get_cache().projects.App.configurations.development.state)
    end)

    it("configure then build → built", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "development",
        success = true,
      })
      core:record_task_result({
        project_key = "App",
        action = "build",
        configuration_key = "development",
        success = true,
      })
      local state = get_cache().projects.App.configurations.development
      assert.equals("built", state.state)
      assert.is_not_nil(state.last_configured)
      assert.is_not_nil(state.last_built)
    end)

    it("records build_dir from result", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "development",
        success = true,
        build_dir = "/root/.nvim/build/App/development",
      })
      assert.equals("/root/.nvim/build/App/development",
        get_cache().projects.App.configurations.development.build_dir)
    end)

    it("records cmake data from result", function()
      local core, get_cache = make_recording_core()
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "development",
        success = true,
        cmake = { compile_commands_dir = "/root/.nvim/build/App/development" },
      })
      assert.equals("/root/.nvim/build/App/development",
        get_cache().projects.App.configurations.development.cmake.compile_commands_dir)
    end)

    it("records tool_data from result", function()
      local core, get_cache = make_recording_core()
      local tool_data = {
        id = "ninja-gcc-14.2.0",
        display = "Ninja - GCC 14.2.0",
        generator = "Ninja",
        compiler_id = "gcc-14.2.0",
        compiler_path = "/usr/bin/g++-14",
      }
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "Debug:ninja-gcc-14.2.0",
        success = true,
        tool_data = tool_data,
      })
      local cached_td = get_cache().projects.App.configurations["Debug:ninja-gcc-14.2.0"].tool_data
      assert.is_not_nil(cached_td)
      assert.equals("ninja-gcc-14.2.0", cached_td.id)
      assert.equals("Ninja - GCC 14.2.0", cached_td.display)
      assert.equals("Ninja", cached_td.generator)
      assert.equals("gcc-14.2.0", cached_td.compiler_id)
    end)

    it("preserves existing tool_data when result has no tool_data", function()
      local core, get_cache = make_recording_core()
      -- First, record with tool_data
      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "Debug",
        success = true,
        tool_data = { id = "ninja-gcc-14.2.0", display = "Ninja - GCC 14.2.0" },
      })
      -- Second, record build without tool_data
      core:record_task_result({
        project_key = "App",
        action = "build",
        configuration_key = "Debug",
        success = true,
      })
      local cached = get_cache().projects.App.configurations.Debug
      assert.equals("built", cached.state)
      assert.equals("ninja-gcc-14.2.0", cached.tool_data.id)
    end)

    it("calls parse_file_api on successful configure and stores targets", function()
      local parse_called = false
      local parse_args = {}
      local saved_cache = nil
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
        },
        nil, nil,
        {
          modules = {
            get = function(mod_type)
              if mod_type ~= "cmake" then return nil end
              return {
                validate = function() return { valid = true, warnings = {} } end,
                info = function() return { configurations = { Debug = {} } } end,
                parse_file_api = function(build_dir, config_name)
                  parse_called = true
                  parse_args = { build_dir = build_dir, config_name = config_name }
                  return {
                    app = { type = "executable", dependencies = { "libcore" } },
                    libcore = { type = "static_library" },
                  }
                end,
              }
            end,
          },
          cache = {
            save = function(_, data) saved_cache = data; return true end,
          },
        }
      )
      core:setup({ root = "/root" })

      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "Debug",
        success = true,
        build_dir = "/root/.nvim/build/App/Debug",
        cmake = { generator = "Ninja" },
      })

      assert.is_true(parse_called, "parse_file_api should be called")
      assert.equals("/root/.nvim/build/App/Debug", parse_args.build_dir)
      assert.equals("Debug", parse_args.config_name)

      -- Targets should be stored in cache
      local cached = saved_cache.projects.App.configurations.Debug
      assert.is_not_nil(cached.cmake.targets)
      assert.equals("executable", cached.cmake.targets.app.type)
      assert.are.same({ "libcore" }, cached.cmake.targets.app.dependencies)
      assert.equals("static_library", cached.cmake.targets.libcore.type)
    end)

    it("does not call parse_file_api on failed configure", function()
      local parse_called = false
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
        },
        nil, nil,
        {
          modules = {
            get = function(mod_type)
              if mod_type ~= "cmake" then return nil end
              return {
                validate = function() return { valid = true, warnings = {} } end,
                info = function() return { configurations = { Debug = {} } } end,
                parse_file_api = function()
                  parse_called = true
                  return nil
                end,
              }
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      core:record_task_result({
        project_key = "App",
        action = "configure",
        configuration_key = "Debug",
        success = false,
        build_dir = "/root/.nvim/build/App/Debug",
      })

      assert.is_false(parse_called, "parse_file_api should not be called on failure")
    end)

    it("does not call parse_file_api on build action", function()
      local parse_called = false
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
        },
        nil, nil,
        {
          modules = {
            get = function(mod_type)
              if mod_type ~= "cmake" then return nil end
              return {
                validate = function() return { valid = true, warnings = {} } end,
                info = function() return { configurations = { Debug = {} } } end,
                parse_file_api = function()
                  parse_called = true
                  return nil
                end,
              }
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      core:record_task_result({
        project_key = "App",
        action = "build",
        configuration_key = "Debug",
        success = true,
        build_dir = "/root/.nvim/build/App/Debug",
      })

      assert.is_false(parse_called, "parse_file_api should not be called for build")
    end)
  end)

  describe("get_project_options", function()
    it("delegates to module get_options with cached build_dir", function()
      local options_args = {}
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
        },
        nil,
        {
          projects = {
            App = {
              type = "cmake",
              configurations = {
                Debug = {
                  state = "configured",
                  build_dir = "/root/.nvim/build/App/Debug",
                },
              },
            },
          },
        },
        {
          modules = {
            get = function(mod_type)
              if mod_type ~= "cmake" then return nil end
              return {
                validate = function() return { valid = true, warnings = {} } end,
                info = function() return { configurations = { Debug = {} } } end,
                get_options = function(build_dir, config)
                  options_args.build_dir = build_dir
                  options_args.config = config
                  return {
                    { label = "Project Options", children = {
                      { key = "BUILD_TESTING", value_type = "bool", value = "ON" },
                    }},
                  }
                end,
              }
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      local options = core:get_config_unit("App", "Debug"):options()
      assert.is_not_nil(options)
      assert.equals(1, #options)
      assert.equals("Project Options", options[1].label)
      assert.equals("BUILD_TESTING", options[1].children[1].key)
      assert.equals("/root/.nvim/build/App/Debug", options_args.build_dir)
    end)

    it("returns nil when project has no build_dir", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
        },
        nil, nil,
        {
          modules = {
            get = function(mod_type)
              if mod_type ~= "cmake" then return nil end
              return {
                validate = function() return { valid = true, warnings = {} } end,
                info = function() return { configurations = { Debug = {} } } end,
                get_options = function() return {} end,
              }
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      local options = core:get_config_unit("App", "Debug"):options()
      assert.is_nil(options)
    end)

    it("returns nil when module has no get_options", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
        },
        nil,
        {
          projects = {
            App = {
              type = "cmake",
              configurations = {
                Debug = { state = "configured", build_dir = "/root/.nvim/build/App/Debug" },
              },
            },
          },
        },
        {
          modules = {
            get = function(mod_type)
              if mod_type ~= "cmake" then return nil end
              return {
                validate = function() return { valid = true, warnings = {} } end,
                info = function() return { configurations = { Debug = {} } } end,
                -- no get_options
              }
            end,
          },
        }
      )
      core:setup({ root = "/root" })

      local options = core:get_config_unit("App", "Debug"):options()
      assert.is_nil(options)
    end)
  end)

  describe("cache version mismatch", function()
    local function make_mismatch_core(dep_overrides)
      -- Provide a cache file with wrong version
      local files = {
        ["loomworks.json"] = h.make_config_json(),
        ["loomworks.cache.json"] = vim.json.encode({
          _meta = { version = 1, loomworks_hash = "", cached_at = "" },
          projects = {},
        }),
      }
      local deps = h.make_test_deps(files, dep_overrides)
      return Core.new(deps), deps
    end

    it("refuses to load workspace on version mismatch", function()
      local core = make_mismatch_core()
      core:setup({ root = "/test" })
      assert.equals("uninitialized", core:state())
      assert.is_nil(core:get_workspace())
    end)

    it("does not modify cache file on version mismatch", function()
      local writes = {}
      local core = make_mismatch_core({
        io = {
          write_json = function(path, data)
            writes[#writes + 1] = path
            return true
          end,
        },
      })
      core:setup({ root = "/test" })
      -- No files should have been written
      assert.equals(0, #writes)
    end)

    it("notifies user on version mismatch", function()
      local notifications = {}
      local core = make_mismatch_core({
        notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
      })
      core:setup({ root = "/test" })
      assert.equals(1, #notifications)
      assert.matches("version mismatch", notifications[1].msg)
      assert.equals(vim.log.levels.ERROR, notifications[1].level)
    end)

    it("stores setup error with root and message", function()
      local core = make_mismatch_core()
      core:setup({ root = "/test" })
      local err = core:get_setup_error()
      assert.is_not_nil(err)
      assert.equals("/test", err.root)
      assert.matches("version mismatch", err.message)
    end)

    it("clears setup error on successful setup", function()
      local core = make_core()
      core:setup({ root = "/test" })
      assert.is_nil(core:get_setup_error())
    end)
  end)

  describe("nuke_cache", function()
    it("deletes build dir, cache file, and backup then reloads", function()
      local deleted = {}
      local core, deps = make_core(nil, nil, nil, {
        io = {
          rm_rf = function(path)
            deleted[#deleted + 1] = path
            return true
          end,
        },
      })
      core:setup({ root = "/test" })

      core:nuke_cache("/test")

      local found_build = false
      local found_cache = false
      local found_bak = false
      for _, p in ipairs(deleted) do
        if p:match("/%.nvim/build$") then found_build = true end
        if p:match("loomworks%.cache%.json$") then found_cache = true end
        if p:match("loomworks%.cache%.json%.bak$") then found_bak = true end
      end
      assert.is_true(found_build, "should delete .nvim/build")
      assert.is_true(found_cache, "should delete cache file")
      assert.is_true(found_bak, "should delete cache backup")
    end)

    it("re-setups after nuke", function()
      local core = make_core()
      core:setup({ root = "/test" })
      -- Nuke clears and re-setups
      core:nuke_cache("/test")
      assert.is_not_nil(core:get_workspace())
    end)

    it("refuses to delete paths outside .nvim/", function()
      local notifications = {}
      local deleted = {}
      local core = make_core(nil, nil, nil, {
        notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
        io = {
          rm_rf = function(path) deleted[#deleted + 1] = path; return true end,
        },
        cache = {
          -- Return a path outside .nvim/ to test safety check
          filepath = function() return "/somewhere/else/cache.json" end,
        },
      })
      core:setup({ root = "/test" })

      core:nuke_cache("/test")

      -- Should have refused and notified
      local found_refuse = false
      for _, n in ipairs(notifications) do
        if n.msg:match("refusing to delete") then found_refuse = true end
      end
      assert.is_true(found_refuse)
      -- Nothing should have been deleted
      assert.equals(0, #deleted)
    end)

    it("refuses when no loomworks.json at root", function()
      local notifications = {}
      local deleted = {}
      local files = {} -- no loomworks.json
      local deps = h.make_test_deps(files, {
        notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
        io = {
          rm_rf = function(path) deleted[#deleted + 1] = path; return true end,
        },
      })
      local core = Core.new(deps)

      core:nuke_cache("/test")

      local found_no_config = false
      for _, n in ipairs(notifications) do
        if n.msg:match("no loomworks%.json") then found_no_config = true end
      end
      assert.is_true(found_no_config)
      assert.equals(0, #deleted)
    end)

    it("refuses relative paths", function()
      local notifications = {}
      local deleted = {}
      local core = make_core(nil, nil, nil, {
        notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end,
        io = {
          rm_rf = function(path) deleted[#deleted + 1] = path; return true end,
        },
      })
      core:setup({ root = "/test" })

      core:nuke_cache("relative/path")

      local found_abs = false
      for _, n in ipairs(notifications) do
        if n.msg:match("absolute path") then found_abs = true end
      end
      assert.is_true(found_abs)
      assert.equals(0, #deleted)
    end)
  end)

  describe("_safe_nvim_path", function()
    it("accepts paths under root/.nvim/", function()
      local core = make_core()
      core:setup({ root = "/test" })
      assert.is_true(core:_safe_nvim_path("/test/.nvim/build", "/test"))
      assert.is_true(core:_safe_nvim_path("/test/.nvim/loomworks.cache.json", "/test"))
      assert.is_true(core:_safe_nvim_path("/test/.nvim/loomworks.cache.json.bak", "/test"))
    end)

    it("accepts the .nvim directory itself", function()
      local core = make_core()
      core:setup({ root = "/test" })
      assert.is_true(core:_safe_nvim_path("/test/.nvim", "/test"))
    end)

    it("rejects paths outside .nvim/", function()
      local core = make_core()
      core:setup({ root = "/test" })
      assert.is_false(core:_safe_nvim_path("/test/src/main.cpp", "/test"))
      assert.is_false(core:_safe_nvim_path("/other/project/.nvim/build", "/test"))
      assert.is_false(core:_safe_nvim_path("/test/.nvim-fake/build", "/test"))
    end)

    -- Directory traversal (e.g. /test/.nvim/../secret) is handled by
    -- vim.fs.normalize which resolves ".." before the prefix check runs.
    -- Not tested here because the test mock doesn't resolve "..".
  end)

  describe("_migrate_set_names", function()
    it("renames cached profile when config set case changes", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { Debug = { App = "Debug" } },
        },
        nil,
        {
          profiles = {
            ["debug:ninja-gcc-12"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local ws = core:get_workspace()
      assert.is_nil(ws.cache.profiles["debug:ninja-gcc-12"])
      assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
      assert.equals("Debug", ws.cache.profiles["Debug:ninja-gcc-12"].configuration_set)
    end)

    it("updates active_profile when migrated", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { Debug = { App = "Debug" } },
        },
        { active_profile = "debug:ninja-gcc-12" },
        {
          profiles = {
            ["debug:ninja-gcc-12"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local ws = core:get_workspace()
      assert.equals("Debug:ninja-gcc-12", ws.user.active_profile)
    end)

    it("no-op when names already match", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { debug = { App = "Debug" } },
        },
        nil,
        {
          profiles = {
            ["debug:ninja-gcc-12"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["debug:ninja-gcc-12"])
      assert.equals("debug", ws.cache.profiles["debug:ninja-gcc-12"].configuration_set)
    end)

    it("skips pinned profiles (no configuration_set)", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { Debug = { App = "Debug" } },
        },
        nil,
        {
          profiles = {
            ["App/Debug:ninja-gcc-12"] = {
              mappings = { App = "Debug" },
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local ws = core:get_workspace()
      assert.is_not_nil(ws.cache.profiles["App/Debug:ninja-gcc-12"])
    end)

    it("handles multiple renames in one pass", function()
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = {
            Debug = { App = "Debug" },
            Release = { App = "Release" },
          },
        },
        nil,
        {
          profiles = {
            ["debug:ninja-gcc-12"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
            ["release:ninja-gcc-12"] = {
              configuration_set = "release",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Release" } },
            },
          },
        }
      )
      core:setup({ root = "/root" })
      local ws = core:get_workspace()
      assert.is_nil(ws.cache.profiles["debug:ninja-gcc-12"])
      assert.is_nil(ws.cache.profiles["release:ninja-gcc-12"])
      assert.is_not_nil(ws.cache.profiles["Debug:ninja-gcc-12"])
      assert.is_not_nil(ws.cache.profiles["Release:ninja-gcc-12"])
      assert.equals("Debug", ws.cache.profiles["Debug:ninja-gcc-12"].configuration_set)
      assert.equals("Release", ws.cache.profiles["Release:ninja-gcc-12"].configuration_set)
    end)

    it("saves cache after migration", function()
      local saved_cache = {}
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { Debug = { App = "Debug" } },
        },
        nil,
        {
          profiles = {
            ["debug:ninja-gcc-12"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
          },
        },
        {
          cache = { save = function(root, data) saved_cache[#saved_cache + 1] = data; return true end },
        }
      )
      core:setup({ root = "/root" })
      assert.is_true(#saved_cache > 0)
      -- The last saved cache should have the renamed profile
      local last = saved_cache[#saved_cache]
      assert.is_not_nil(last.profiles["Debug:ninja-gcc-12"])
    end)

    it("saves user.json when active_profile changes", function()
      local saved_user = {}
      local core = make_core(
        {
          projects = { App = { cmake = {} } },
          configuration_sets = { Debug = { App = "Debug" } },
        },
        { active_profile = "debug:ninja-gcc-12" },
        {
          profiles = {
            ["debug:ninja-gcc-12"] = {
              configuration_set = "debug",
              tool_key = "ninja-gcc-12",
              projects = { App = { config_key = "Debug" } },
            },
          },
        },
        {
          user = { save = function(root, data) saved_user[#saved_user + 1] = data; return true end },
        }
      )
      core:setup({ root = "/root" })
      assert.is_true(#saved_user > 0)
      -- The saved user data should have the new active_profile
      local found = false
      for _, u in ipairs(saved_user) do
        if u.active_profile == "Debug:ninja-gcc-12" then found = true end
      end
      assert.is_true(found, "user.json should have been saved with migrated active_profile")
    end)
  end)

end)
