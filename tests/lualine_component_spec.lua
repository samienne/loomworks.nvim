-- The lualine/winbar component renders workspace data (set names, project
-- keys, configuration names, tool and profile keys) into a statusline string,
-- where `%` starts a statusline item (`%#Group#`, `%{expr}`, `%!`, …). Those
-- names can come from a cloned loomworks.json, so each one must reach the
-- statusline inert: `%` doubled to `%%` and control characters removed
-- (spec/ui.md §3, core §17.11). The component's own highlight escapes are
-- unaffected. Status markers colour through lualine highlights (create_hl /
-- format_hl / get_default_hl), never raw `%#Group#…%*` escapes.

-- Minimal stand-in for lualine's component base class (lualine is not a test
-- dependency): `extend()` returns a subclass whose `super.init` stores options;
-- the highlight helpers mimic lualine's naming (`lualine_<section>_<name>`)
-- and keep the colour function so tests can evaluate it.
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
  function Base:create_hl(color, hint)
    return { name = "lualine_c_loomworks_" .. hint, fn = color }
  end
  function Base:format_hl(token) return "%#" .. token.name .. "#" end
  function Base:get_default_hl() return "%#lualine_c_normal#" end
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
    assert.is_truthy(s:find("%#lualine_c_loomworks_DiagnosticWarn#\u{26a0}%#lualine_c_normal#", 1, true))
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

describe("lualine component: status marker highlights", function()
  local saved, saved_hl
  before_each(function()
    saved = package.loaded["loomworks"]
    saved_hl = vim.api.nvim_get_hl(0, { name = "DiagnosticOk", link = false })
  end)
  after_each(function()
    package.loaded["loomworks"] = saved
    vim.api.nvim_set_hl(0, "DiagnosticOk", saved_hl)
  end)

  it("colours markers via lualine highlights and returns to the section hl", function()
    package.loaded["loomworks"] = { buf_status = function()
      return { set_name = "dev", profile_state = "built", project = "App",
               configuration = "Debug", status = "unconfigured", diagnostic_severity = "error" }
    end }
    local c = new_component({ show = { "diagnostics", "set_name", "project", "configuration" },
      icons = { set_name = false, project = false } })
    local s = c:update_status()
    assert.is_truthy(s:find("%#lualine_c_loomworks_DiagnosticError#\u{2717}%#lualine_c_normal#", 1, true))
    assert.is_truthy(s:find("%#lualine_c_loomworks_DiagnosticOk#\u{2713}%#lualine_c_normal# dev", 1, true))
    assert.is_truthy(s:find("%#lualine_c_loomworks_DiagnosticError#\u{25cb}%#lualine_c_normal# App/Debug", 1, true))
    -- No raw escapes: `%*` would reset to StatusLine/WinBar, and a bare
    -- Diagnostic group carries no section background.
    assert.is_nil(s:find("%*", 1, true))
    assert.is_nil(s:find("%#Diagnostic", 1, true))
    assert.is_nil(s:find("%#Comment#", 1, true))
  end)

  it("unknown states fall back to Comment", function()
    local c = new_component({})
    assert.equals("%#lualine_c_loomworks_Comment#?%#lualine_c_normal# ", c:_status_marker("unknown"))
  end)

  it("creates one highlight per marker group in init", function()
    local c = new_component({})
    for _, g in ipairs({ "DiagnosticOk", "DiagnosticWarn", "DiagnosticError", "Comment" }) do
      assert.is_not_nil(c._marker_hls[g], g)
      assert.equals("function", type(c._marker_hls[g].fn))
    end
  end)

  it("takes only the group's foreground, re-read on every redraw", function()
    local c = new_component({})
    local fn = c._marker_hls.DiagnosticOk.fn
    vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0x123456, bg = 0x654321 })
    assert.same({ fg = "#123456" }, fn())
    -- Colorscheme change: the next evaluation sees the new colour.
    vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0xabcdef })
    assert.same({ fg = "#abcdef" }, fn())
    -- No foreground: an empty colour, lualine uses the section's own.
    vim.api.nvim_set_hl(0, "DiagnosticOk", {})
    assert.same({}, fn())
  end)
end)
