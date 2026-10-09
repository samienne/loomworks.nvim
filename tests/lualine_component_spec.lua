-- The lualine/winbar component renders workspace data (set names, project
-- keys, configuration names, tool and profile keys) into a statusline string,
-- where `%` starts a statusline item (`%#Group#`, `%{expr}`, `%!`, …). Those
-- names can come from a cloned loomworks.json, so each one must reach the
-- statusline inert: `%` doubled to `%%` and control characters removed
-- (spec/ui.md §3, core §17.11). The component's own highlight escapes
-- (`%#hl#…%*`) are unaffected.

-- Minimal stand-in for lualine's component base class (lualine is not a test
-- dependency): `extend()` returns a subclass whose `super.init` stores options.
package.loaded["lualine.component"] = nil
package.preload["lualine.component"] = function()
  local Base = {}
  Base.__index = Base
  function Base:extend()
    local cls = setmetatable({}, { __index = self })
    cls.__index = cls
    cls.super = self
    return cls
  end
  function Base:init(options) self.options = options end
  return Base
end

local function new_component(opts)
  package.loaded["lualine.components.loomworks"] = nil
  local cls = require("lualine.components.loomworks")
  local c = setmetatable({}, cls)
  c:init(opts or {})
  return c
end

describe("lualine component: workspace data is statusline-inert", function()
  local saved
  before_each(function() saved = package.loaded["loomworks"] end)
  after_each(function() package.loaded["loomworks"] = saved end)

  local function with_status(status)
    package.loaded["loomworks"] = { buf_status = function() return status end }
  end

  it("escapes % in every rendered name", function()
    with_status({
      set_name = "50%#ErrorMsg#x",
      project = "App%{v:true}",
      configuration = "Deb%!ug",
      tool_key = "gcc%=12",
      profile_key = "p%%k",
    })
    local c = new_component({
      show = { "set_name", "project", "configuration", "tool_key", "profile_key" },
      icons = {},
      status_icons = false,
    })
    local s = c:update_status()
    assert.is_truthy(s:find("50%%#ErrorMsg#x", 1, true))
    assert.is_truthy(s:find("App%%{v:true}/Deb%%!ug [gcc%%=12]", 1, true))
    assert.is_truthy(s:find("p%%%%k", 1, true))
    -- No lone `%` survives from the data: strip every `%%` pair, then no `%`
    -- is left (the component's own escapes are disabled in this config).
    assert.is_nil(s:gsub("%%%%", ""):find("%", 1, true))
  end)

  it("removes control characters from names", function()
    with_status({ set_name = "a\027]0;pwn\007b\nc" })
    local c = new_component({ show = { "set_name" }, icons = {}, status_icons = false })
    local s = c:update_status()
    assert.is_truthy(s:find("a]0;pwnbc", 1, true))
    assert.is_nil(s:find("%c"))
  end)

  it("keeps the component's own highlight escapes", function()
    with_status({ set_name = "dev", diagnostic_severity = "warn" })
    local c = new_component({ show = { "diagnostics", "set_name" }, icons = {}, status_icons = false })
    local s = c:update_status()
    assert.is_truthy(s:find("%#DiagnosticWarn#", 1, true))
    assert.is_truthy(s:find("dev", 1, true))
  end)
end)

describe("lualine component: in-process view changes redraw at once", function()
  -- An in-process view is built on read: init.lua tells the view store when
  -- the model may have changed (here `task_started`), the store redraws the
  -- statusline, and the render that then shows a running state starts the
  -- spinner timer. The component itself subscribes to no loomworks event.
  local lw = require("loomworks")
  local events = require("loomworks.events")
  local saved_status, saved_cmd

  before_each(function()
    saved_status = lw.buf_status
    saved_cmd = vim.cmd
    package.loaded["loomworks"] = lw
  end)
  after_each(function()
    lw.buf_status = saved_status
    vim.cmd = saved_cmd
  end)

  it("a task start redraws the statusline and the running state starts the spinner", function()
    local state = "built"
    lw.buf_status = function() return { project = "App", configuration = "Debug", status = state } end
    local c = new_component({ show = { "project" }, icons = {} })
    local redraws = 0
    -- Stand in for lualine: each redrawstatus renders the component.
    vim.cmd = function(cmd)
      if cmd == "redrawstatus" then
        redraws = redraws + 1
        c:update_status()
        return
      end
      return saved_cmd(cmd)
    end
    c:update_status() -- idle render: no timer
    vim.wait(200)
    assert.equals(0, redraws)

    state = "building"
    events.emit("task_started", { name = "build" })
    -- The store's redraw comes on the next event-loop turn ...
    assert.is_true(vim.wait(100, function() return redraws >= 1 end, 5))
    -- ... and the spinner timer (80 ms) keeps redrawing after it.
    assert.is_true(vim.wait(1000, function() return redraws >= 4 end, 5))

    -- Idle again: the timer stops on its own (IDLE_STOP_MS after the last
    -- running render).
    state = "built"
    events.emit("task_stopped", {})
    local last = -1
    assert.is_true(vim.wait(4000, function()
      local stable = redraws == last
      last = redraws
      return stable
    end, 300))
  end)
end)
