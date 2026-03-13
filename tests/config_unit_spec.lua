local h = require("tests.helpers")
local ConfigUnit = require("loomworks.config_unit")

describe("ConfigUnit", function()
  local function make_unit(core_overrides)
    local core = h.make_mock_core(core_overrides)
    local unit = core:get_config_unit("App", "Debug")
    return unit, core
  end

  describe("identity", function()
    it("stores project_key and config_key", function()
      local unit = make_unit()
      assert.equals("App", unit.project_key)
      assert.equals("Debug", unit.config_key)
    end)

  end)

  describe("registry", function()
    it("returns same instance for same key pair", function()
      local core = h.make_mock_core()
      local u1 = core:get_config_unit("App", "Debug")
      local u2 = core:get_config_unit("App", "Debug")
      assert.equals(u1, u2)
      assert.is_true(rawequal(u1, u2))
    end)

    it("returns different instances for different keys", function()
      local core = h.make_mock_core()
      local u1 = core:get_config_unit("App", "Debug")
      local u2 = core:get_config_unit("App", "Release")
      local u3 = core:get_config_unit("Lib", "Debug")
      assert.is_false(rawequal(u1, u2))
      assert.is_false(rawequal(u1, u3))
    end)
  end)

  describe("state", function()
    it("returns unconfigured by default", function()
      local unit = make_unit()
      assert.equals("unconfigured", unit:state())
    end)

    it("returns cached state when present", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "built" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.equals("built", unit:state())
    end)

    it("maps failed_configure to configure_failed", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "failed_configure" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.equals("configure_failed", unit:state())
    end)

    it("maps failed_build to build_failed", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "failed_build" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.equals("build_failed", unit:state())
    end)

    it("returns configuring when configure task is running", function()
      local unit = make_unit()
      unit:register_task(1, "configure")
      assert.equals("configuring", unit:state())
    end)

    it("returns building when build task is running", function()
      local unit = make_unit()
      unit:register_task(1, "build")
      assert.equals("building", unit:state())
    end)

    it("running state takes priority over cached state", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
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
      unit:register_task(1, "build")
      assert.equals("building", unit:state())
    end)

    it("returns deleting when marked", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      assert.equals("deleting", unit:state())
    end)

    it("deleting takes priority over running", function()
      local unit = make_unit()
      unit:register_task(1, "build")
      unit:mark_deleting(true)
      assert.equals("deleting", unit:state())
    end)

    it("returns unknown when cached state is unknown", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "unknown" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.equals("unknown", unit:state())
    end)
  end)

  describe("is_running", function()
    it("returns false by default", function()
      local unit = make_unit()
      assert.is_false(unit:is_running())
    end)

    it("returns true when task registered", function()
      local unit = make_unit()
      unit:register_task(1, "configure")
      assert.is_true(unit:is_running())
    end)

    it("returns false after task unregistered", function()
      local unit = make_unit()
      unit:register_task(1, "configure")
      unit:unregister_task(1)
      assert.is_false(unit:is_running())
    end)
  end)

  describe("running_action", function()
    it("returns nil by default", function()
      local unit = make_unit()
      assert.is_nil(unit:running_action())
    end)

    it("returns the action of the running task", function()
      local unit = make_unit()
      unit:register_task(1, "build")
      assert.equals("build", unit:running_action())
    end)
  end)

  describe("register_task / unregister_task", function()
    it("tracks the task id", function()
      local unit = make_unit()
      unit:register_task(42, "configure")
      assert.equals(42, unit._task_id)
      assert.equals("configure", unit._action)
    end)

    it("unregister clears state", function()
      local unit = make_unit()
      unit:register_task(42, "configure")
      unit:unregister_task(42)
      assert.is_nil(unit._task_id)
      assert.is_nil(unit._action)
      assert.is_nil(unit._progress)
      assert.is_nil(unit._start_time)
    end)

    it("unregister ignores mismatched task id", function()
      local unit = make_unit()
      unit:register_task(42, "configure")
      unit:unregister_task(99)
      assert.equals(42, unit._task_id)
      assert.equals("configure", unit._action)
    end)

    it("register clears previous progress", function()
      local unit = make_unit()
      unit:register_task(1, "configure")
      unit:update_progress(1, { current = 5, total = 10 })
      unit:register_task(2, "build")
      assert.is_nil(unit:progress())
    end)
  end)

  describe("progress", function()
    it("returns nil by default", function()
      local unit = make_unit()
      assert.is_nil(unit:progress())
    end)

    it("returns progress after update", function()
      local unit = make_unit()
      unit:register_task(1, "build")
      unit:update_progress(1, { current = 3, total = 10 })
      local p = unit:progress()
      assert.equals(3, p.current)
      assert.equals(10, p.total)
    end)

    it("ignores update for wrong task id", function()
      local unit = make_unit()
      unit:register_task(1, "build")
      unit:update_progress(99, { current = 3, total = 10 })
      assert.is_nil(unit:progress())
    end)
  end)

  describe("elapsed", function()
    it("returns nil when no task running", function()
      local unit = make_unit()
      assert.is_nil(unit:elapsed())
    end)

    it("returns elapsed time from clock", function()
      local time = 100
      local core = h.make_mock_core()
      core._deps = { clock = function() return time end }
      local unit = core:get_config_unit("App", "Debug")

      unit:register_task(1, "build")
      time = 105
      assert.equals(5, unit:elapsed())
    end)
  end)

  describe("cached_state", function()
    it("returns nil when no workspace", function()
      local unit = make_unit()
      assert.is_nil(unit:cached_state())
    end)

    it("returns cached config when present", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "built", build_dir = "/build/App/Debug" },
                  },
                },
              },
            },
          }
        end,
      })
      local cached = unit:cached_state()
      assert.equals("built", cached.state)
      assert.equals("/build/App/Debug", cached.build_dir)
    end)
  end)

  describe("build_dir", function()
    it("returns nil when no cached state", function()
      local unit = make_unit()
      assert.is_nil(unit:build_dir())
    end)

    it("returns build_dir from cached state", function()
      local unit = make_unit({
        get_workspace = function()
          return {
            cache = {
              projects = {
                App = {
                  configurations = {
                    Debug = { state = "configured", build_dir = "/build/App/Debug" },
                  },
                },
              },
            },
          }
        end,
      })
      assert.equals("/build/App/Debug", unit:build_dir())
    end)
  end)

  describe("is_deleting", function()
    it("returns false by default", function()
      local unit = make_unit()
      assert.is_false(unit:is_deleting())
    end)

    it("returns true when marked", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      assert.is_true(unit:is_deleting())
    end)

    it("returns false after unmarked", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      unit:mark_deleting(false)
      assert.is_false(unit:is_deleting())
    end)
  end)

  describe("listeners", function()
    it("fires on register_task", function()
      local unit = make_unit()
      local called = 0
      unit:on_state_change(function() called = called + 1 end)
      unit:register_task(1, "configure")
      assert.equals(1, called)
    end)

    it("fires on unregister_task", function()
      local unit = make_unit()
      local states = {}
      unit:on_state_change(function(u) states[#states + 1] = u:state() end)
      unit:register_task(1, "configure")
      unit:unregister_task(1)
      assert.equals(2, #states)
      assert.equals("configuring", states[1])
      assert.equals("unconfigured", states[2])
    end)

    it("fires on mark_deleting", function()
      local unit = make_unit()
      local called = false
      unit:on_state_change(function() called = true end)
      unit:mark_deleting(true)
      assert.is_true(called)
    end)

    it("fires on update_progress", function()
      local unit = make_unit()
      local called = false
      unit:on_state_change(function() called = true end)
      unit:register_task(1, "build")
      called = false
      unit:update_progress(1, { current = 1, total = 5 })
      assert.is_true(called)
    end)

    it("multiple listeners all fire", function()
      local unit = make_unit()
      local a, b = 0, 0
      unit:on_state_change(function() a = a + 1 end)
      unit:on_state_change(function() b = b + 1 end)
      unit:register_task(1, "build")
      assert.equals(1, a)
      assert.equals(1, b)
    end)
  end)

  describe("queued_action", function()
    it("returns nil by default", function()
      local unit = make_unit()
      assert.is_nil(unit:queued_action())
    end)

    it("stores queued action while deleting", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      unit:queue_action("build")
      assert.equals("build", unit:queued_action())
    end)

    it("ignores queue_action when not deleting", function()
      local unit = make_unit()
      unit:queue_action("build")
      assert.is_nil(unit:queued_action())
    end)

    it("replaces previous queued action", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      unit:queue_action("configure")
      unit:queue_action("build")
      assert.equals("build", unit:queued_action())
    end)

    it("pop_queued_action returns and clears the action", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      unit:queue_action("build")
      local action = unit:pop_queued_action()
      assert.equals("build", action)
      assert.is_nil(unit:queued_action())
    end)

    it("mark_deleting(false) clears queued action", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      unit:queue_action("build")
      unit:mark_deleting(false)
      assert.is_nil(unit:queued_action())
    end)

    it("fires listener on queue_action", function()
      local unit = make_unit()
      unit:mark_deleting(true)
      local called = false
      unit:on_state_change(function() called = true end)
      unit:queue_action("build")
      assert.is_true(called)
    end)
  end)

  describe("shared state across profiles", function()
    it("same unit visible from two profiles", function()
      local core = h.make_mock_core()
      local u1 = core:get_config_unit("App", "debug")
      local u2 = core:get_config_unit("App", "debug")

      u1:register_task(1, "configure")
      assert.equals("configuring", u2:state())
      assert.is_true(u2:is_running())
    end)
  end)
end)
