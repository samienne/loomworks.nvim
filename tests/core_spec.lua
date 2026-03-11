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
    it("registers and queries via ConfigUnit", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local unit = core:get_config_unit("App", "Debug")
      unit:register_task(42, "build")
      assert.is_true(core:has_running_tasks())
      assert.equals("build", core:get_project_running_action("App"))
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

    it("returns nil for non-running project", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_nil(core:get_project_running_action("App"))
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

    it("has_pending_deletions reflects ConfigUnit state", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_false(core:has_pending_deletions())
      core:get_config_unit("App", "Debug"):mark_deleting(true)
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

  describe("deactivate_profile", function()
    it("clears active profile when it matches", function()
      local saved = {}
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
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
      core:deactivate_profile("debug")
      assert.is_nil(saved.data.active_profile)
    end)

    it("does nothing when profile does not match active", function()
      local save_called = false
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        { active_profile = "debug" },
        nil,
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
      core:deactivate_profile("release")
      assert.is_false(save_called)
    end)

    it("is safe without workspace", function()
      local core = make_core()
      -- don't setup
      core:deactivate_profile("debug") -- should not error
    end)
  end)

  describe("activate_set", function()
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
      core:activate_set("release")
      assert.equals("release", saved.data.active_profile)
    end)

    it("is safe without workspace", function()
      local core = make_core()
      core:activate_set("debug") -- should not error
    end)
  end)

  describe("materialize_profile", function()
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
      core:materialize_profile("debug")

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
      core:materialize_profile("debug")
      local count_after_first = save_count
      core:materialize_profile("debug")
      assert.equals(count_after_first, save_count) -- no additional save
    end)

    it("is safe without workspace", function()
      local core = make_core()
      -- don't setup
      core:materialize_profile("debug") -- should not error
    end)

    it("is safe with unknown profile", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        }
      )
      core:setup({ root = "/root" })
      core:materialize_profile("nonexistent") -- should not error
    end)

    it("remerges after materialization", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
          configuration_sets = { debug = { App = "development" } },
        },
        nil, nil,
        {
          cache = {
            save = function() return true end,
          },
        }
      )
      core:setup({ root = "/root" })
      local gen = core._generation
      core:materialize_profile("debug")
      assert.is_true(core._generation > gen)
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

    it("returns empty when no matches", function()
      local core = make_core()
      core:setup({ root = "/root" })
      local matches = core:find_running_tasks_for_items({
        { project_key = "App", config_key = "Debug" },
      })
      assert.are.same({}, matches)
    end)
  end)

  describe("stop_tasks_then", function()
    it("calls on_done immediately for empty list", function()
      local core = make_core()
      local done = false
      core:stop_tasks_then({}, function() done = true end)
      assert.is_true(done)
    end)

    it("calls on_done for already-complete tasks", function()
      local done = false
      local core = make_core(nil, nil, nil, {
        get_overseer_task = function() return nil end, -- task not found
      })
      core:stop_tasks_then({ 1, 2 }, function() done = true end)
      assert.is_true(done)
    end)
  end)

  describe("plan_config_deletion", function()
    it("includes config when only ad-hoc profiles reference it", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
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
      local plan = core:plan_config_deletion("App", "development")
      assert.equals(1, #plan.items)
      assert.equals("App", plan.items[1].project_key)
      assert.equals("/root/.nvim/build/App/development", plan.items[1].build_dir)
      assert.is_not_nil(plan.adhoc_profiles)
      assert.equals(1, #plan.adhoc_profiles)
      assert.is_true(plan.defined_in_config)
    end)

    it("returns empty plan when no workspace", function()
      local core = make_core()
      -- don't setup
      local plan = core:plan_config_deletion("App", "Debug")
      assert.are.same({}, plan.items)
      assert.is_false(plan.defined_in_config)
    end)

    it("excludes config when a full profile references it", function()
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
      local plan = core:plan_config_deletion("App", "Debug:ninja-gcc")
      -- Config is referenced by full profile — disposition is "reset"
      assert.equals(1, #plan.items)
      assert.equals("reset", plan.items[1].disposition)
    end)
  end)

  describe("delete_cached_configs", function()
    it("removes config from cache and saves", function()
      local saved_cache = nil
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built", build_dir = "/root/.nvim/build/App/development" },
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
      core:delete_cached_configs({
        { project_key = "App", config_key = "development" },
      })
      assert.is_not_nil(saved_cache)
      -- Project should be removed since no configs left
      assert.is_nil(saved_cache.projects.App)
    end)

    it("refuses to delete build dir outside .nvim/build", function()
      local notifications = {}
      local core = make_core(
        { projects = { App = { typescript = {} } } },
        nil,
        {
          projects = {
            App = {
              type = "typescript",
              configurations = {
                development = { state = "built", build_dir = "/root/src/App" },
              },
            },
          },
        },
        {
          cache = { save = function() return true end },
          notify = function(msg, level)
            notifications[#notifications + 1] = { msg = msg, level = level }
          end,
        }
      )
      core:setup({ root = "/root" })
      core:delete_cached_configs({
        { project_key = "App", config_key = "development" },
      })
      local found_refusal = false
      for _, n in ipairs(notifications) do
        if n.msg:match("refusing to delete") then
          found_refusal = true
          break
        end
      end
      assert.is_true(found_refusal)
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
      core:execute_deletion(plan, { deactivate_profile = "debug" }, function() done = true end)
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
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
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

      local refs = core:find_referencing_profiles("App", "development")
      assert.equals(1, #refs)
      assert.equals("adhoc:App:development", refs[1])
    end)

    it("returns empty when no profiles reference config", function()
      local core = make_core(
        {
          projects = { App = { typescript = {} } },
        },
        nil,
        {
          profiles = {
            ["adhoc:App:development"] = {
              ad_hoc = true,
              project_key = "App",
              config_key = "development",
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

      local refs = core:find_referencing_profiles("App", "production")
      assert.equals(0, #refs)
    end)
  end)

  describe("_adopt_orphaned_configs", function()
    it("creates ad-hoc profile for orphaned built config", function()
      local saved_cache = nil
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
      assert.is_not_nil(saved_cache.profiles)
      assert.is_not_nil(saved_cache.profiles["adhoc:App:development"])
      local adhoc = saved_cache.profiles["adhoc:App:development"]
      assert.is_true(adhoc.ad_hoc)
      assert.equals("App", adhoc.project_key)
      assert.equals("development", adhoc.config_key)
    end)

    it("silently drops unconfigured skeleton", function()
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
      -- No ad-hoc profile created
      assert.is_nil(saved_cache.profiles)
    end)

    it("does not adopt configs already referenced by a profile", function()
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

  describe("operations", function()
    it("tracks a running operation", function()
      local time = 100
      local core = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      core:start_operation("debug", "build")

      local op = core:get_operation("debug")
      assert.is_not_nil(op)
      assert.equals("build", op.action)
      assert.equals(100, op.started_at)

      time = 130
      assert.equals(30, core:get_operation_elapsed("debug"))
    end)

    it("finishes operation with success message", function()
      local time = 100
      local core = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      core:start_operation("debug", "build")
      time = 190
      core:finish_operation("debug", true)

      local op = core:get_operation("debug")
      assert.is_not_nil(op)
      assert.equals("built in 1m30s", op.message)
      assert.is_true(op.success)
      -- No longer running
      assert.is_nil(core:get_operation_elapsed("debug"))
    end)

    it("finishes operation with failure message", function()
      local time = 0
      local core = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      core:start_operation("debug", "configure")
      time = 45
      core:finish_operation("debug", false)

      local op = core:get_operation("debug")
      assert.equals("configure failed in 45s", op.message)
      assert.is_false(op.success)
    end)

    it("configure+build operation uses generic verb", function()
      local time = 0
      local core = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      core:start_operation("debug", "configure+build")
      time = 120
      core:finish_operation("debug", true)

      assert.equals("built in 2m00s", core:get_operation("debug").message)
    end)

    it("new operation replaces previous result", function()
      local time = 0
      local core = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      core:start_operation("debug", "build")
      time = 10
      core:finish_operation("debug", true)
      assert.is_not_nil(core:get_operation("debug").message)

      core:start_operation("debug", "build")
      -- Previous result replaced by running state
      assert.is_not_nil(core:get_operation("debug").started_at)
      assert.is_nil(core:get_operation("debug").message)
    end)

    it("returns nil for unknown profile", function()
      local core = make_core()
      core:setup({ root = "/root" })
      assert.is_nil(core:get_operation("nonexistent"))
      assert.is_nil(core:get_operation_elapsed("nonexistent"))
    end)

    it("emits operation events", function()
      local time = 0
      local core, deps = make_core(nil, nil, nil, {
        clock = function() return time end,
      })
      core:setup({ root = "/root" })
      core:start_operation("debug", "build")
      time = 10
      core:finish_operation("debug", true)

      local events = deps._events_log
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
  end)

end)
