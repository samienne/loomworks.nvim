--- lualine component for loomworks — shows active project/configuration/tool.
---
--- Usage in lualine config:
---   { "loomworks" }                           -- default: ⚙ ✓ debug > 📁 ✓ App/Debug [ninja-gcc-12]
---   { "loomworks", show = { "project" } }     -- just the project name
---   { "loomworks", icons = {} }               -- disable icons globally
---   { "loomworks", icons = { project = "" } } -- override single icon
---   { "loomworks", status_icons = false }     -- disable status icons + spinner
---
--- Available show fields: "diagnostics", "set_name", "project",
---     "configuration", "tool_key", "profile_key", "status".
--- "diagnostics" prepends a `⚠` (or `✗` for error severity) when the
--- workspace has active diagnostics — same warning surface as the
--- status-page Diagnostics section. Highlight uses DiagnosticWarn /
--- DiagnosticError. Drop "diagnostics" from `show` to disable.
---
--- Icons (nerd font glyphs) are prepended to each shown field. Set a
--- field to `false` or `""` to drop just that icon; pass `icons = {}`
--- to drop all of them.
---
--- Status icons:
---   - Profile (set_name) gets the aggregate-state marker from
---     `status.profile_state`.
---   - Project/config gets the per-config marker from `status.status`.
---   - Running states (configuring/building/deleting) animate the
---     spinner. The animation is driven by a module-level uv timer that
---     starts on `task_started` and stops when the running-task count
---     hits zero, so there's zero refresh cost while the workspace is
---     idle. `status_icons = false` disables both icons and the timer.

local M = require("lualine.component"):extend()

local default_options = {
    show = { "diagnostics", "set_name", "project", "configuration", "tool_key" },
    join = " \u{e0b1} ",
    icons = {
        set_name      = "\u{f085}",  -- nf-fa-cogs — profile/set
        project       = "\u{f07b}",  -- nf-fa-folder — project (carries the config too)
        configuration = false,        -- inline with project; no separate icon
        tool_key      = false,        -- inline with project; no separate icon
        profile_key   = false,
    },
    status_icons = true,
}

-- ---------------------------------------------------------------------------
-- Status icon mapping
-- ---------------------------------------------------------------------------

--- Single-state → icon glyph. Mirrors the status page's STATUS_ICON
--- map (`ui/helpers.lua`) so the winbar and the status page agree on
--- what each state looks like.
local STATUS_ICON = {
    unconfigured     = "\u{25cb}",  -- ○
    configured       = "\u{25d0}",  -- ◐
    built            = "\u{2713}",  -- ✓
    configure_failed = "\u{2717}",  -- ✗
    build_failed     = "\u{2717}",  -- ✗
    failed_configure = "\u{2717}",  -- ✗ (profile_state alias)
    failed_build     = "\u{2717}",  -- ✗ (profile_state alias)
    unknown          = "?",
    mixed            = "\u{25cb}",  -- ○ (neutral aggregate when configs disagree)
}

--- Highlight group per state. Maps to standard Diagnostic groups so
--- the marker reads independently of any surrounding text colour.
local STATUS_HL = {
    built            = "DiagnosticOk",
    configure_failed = "DiagnosticError",
    build_failed     = "DiagnosticError",
    failed_configure = "DiagnosticError",
    failed_build     = "DiagnosticError",
    configuring      = "DiagnosticWarn",
    building         = "DiagnosticWarn",
    deleting         = "DiagnosticError",
    cleaning         = "DiagnosticError",
}

--- True if a state should animate the spinner instead of showing a
--- static icon.
local RUNNING_STATES = {
    configuring = true, building = true,
    deleting = true, cleaning = true,
}

-- ---------------------------------------------------------------------------
-- Spinner timer (module-level singleton)
-- ---------------------------------------------------------------------------

--- 80ms frame interval matches the status page so multiple windows
--- showing loomworks state stay in sync.
local SPINNER_FRAMES = { "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}",
    "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}",
    "\u{2807}", "\u{280f}" }
local SPINNER_INTERVAL_MS = 80

local _uv = vim.uv or vim.loop
local _timer = nil
local _running_count = 0
local _events_attached = false

--- Frame index derived from monotonic time so all callers within a
--- given tick agree on the frame without holding shared mutable state.
--- @return string
local function spinner_frame()
    local ms = _uv.hrtime() / 1e6
    local idx = math.floor(ms / SPINNER_INTERVAL_MS) % #SPINNER_FRAMES + 1
    return SPINNER_FRAMES[idx]
end

local function stop_timer()
    if not _timer then return end
    pcall(function() _timer:stop(); _timer:close() end)
    _timer = nil
end

local function maybe_start_timer()
    if _timer or _running_count == 0 then return end
    _timer = _uv.new_timer()
    -- Manual statusline refresh — lualine's own timer is too slow for
    -- spinner animation (1s default). We could lower it globally but
    -- that affects every other component too; cheaper to just kick
    -- redrawstatus ~12 times per second only while tasks are active.
    _timer:start(0, SPINNER_INTERVAL_MS, vim.schedule_wrap(function()
        if _running_count > 0 then
            pcall(vim.cmd, "redrawstatus")
        else
            stop_timer()
        end
    end))
end

--- Attach the task_started/task_stopped listeners exactly once per
--- nvim session. Safe to call from every component instance; later
--- calls no-op via the `_events_attached` guard.
local function attach_events()
    if _events_attached then return end
    local ok, events = pcall(require, "loomworks.events")
    if not ok then return end
    _events_attached = true
    events.on("task_started", function()
        _running_count = _running_count + 1
        maybe_start_timer()
    end)
    events.on("task_stopped", function()
        _running_count = math.max(0, _running_count - 1)
        if _running_count == 0 then stop_timer() end
    end)
end

-- ---------------------------------------------------------------------------
-- Component implementation
-- ---------------------------------------------------------------------------

function M:init(options)
    M.super.init(self, options)
    self.options = vim.tbl_deep_extend("keep", self.options or {}, default_options)

    -- Build a lookup set for fast checking
    self._show = {}
    for _, field in ipairs(self.options.show) do
        self._show[field] = true
    end

    -- Normalize icons table: nil / false / empty string all mean "no
    -- icon for this field"; anything else is the literal prefix to
    -- prepend (followed by a space).
    self._icons = {}
    for field, glyph in pairs(self.options.icons or {}) do
        if glyph and glyph ~= "" then
            self._icons[field] = glyph .. " "
        end
    end

    if self.options.status_icons ~= false then
        attach_events()
    end
end

--- Prepend the configured icon (if any) to a field's rendered value.
--- @param field string
--- @param value string
--- @return string
function M:_with_icon(field, value)
    local icon = self._icons[field]
    if not icon then return value end
    return icon .. value
end

--- Render a status icon (spinner frame for running states; mapped
--- glyph otherwise) wrapped in a statusline highlight escape. Returns
--- the empty string for unknown / nil states so callers can append
--- unconditionally.
--- @param state string|nil
--- @return string
function M:_status_marker(state)
    if not state or self.options.status_icons == false then return "" end
    local hl = STATUS_HL[state] or "Comment"
    local glyph
    if RUNNING_STATES[state] then
        glyph = spinner_frame()
    else
        glyph = STATUS_ICON[state]
    end
    if not glyph then return "" end
    return "%#" .. hl .. "#" .. glyph .. "%* "
end

function M:update_status()
    -- Use package.loaded to avoid triggering lazy.nvim's module loader,
    -- which can cause circular dependency during startup.
    local lw = package.loaded["loomworks"]
    if not lw then return "" end

    local status = lw.buf_status()
    if not status then return "" end

    local parts = {}

    -- Diagnostics indicator: a single icon coloured by severity. Sits
    -- before everything else so it stays visible if the rest of the
    -- segment overflows / scrolls. Statusline highlight escapes
    -- (`%#hl#text%*`) are interpreted by vim, so we render coloured
    -- without any lualine-specific machinery.
    if self._show.diagnostics and status.diagnostic_severity then
        local hl = status.diagnostic_severity == "error"
            and "DiagnosticError" or "DiagnosticWarn"
        local icon = status.diagnostic_severity == "error"
            and "\u{2717}" or "\u{26a0}"   -- ✗ or ⚠
        parts[#parts + 1] = "%#" .. hl .. "#" .. icon .. "%*"
    end

    -- Set name: "debug". Status marker (from profile_state) precedes
    -- the field icon so the order reads:
    --   <status icon> <profile icon> <set name>.
    if self._show.set_name and status.set_name then
        local marker = self:_status_marker(status.profile_state)
        parts[#parts + 1] = marker .. self:_with_icon("set_name", status.set_name)
    end

    -- Project and configuration: "App/Debug" or just "App"
    local project_part
    if self._show.project and status.project then
        if self._show.configuration and status.configuration then
            project_part = status.project .. "/" .. status.configuration
        else
            project_part = status.project
        end
    elseif self._show.configuration and status.configuration then
        project_part = status.configuration
    end

    -- Tool key in brackets appended to project: "App/Debug [ninja-gcc-12]"
    if project_part then
        if self._show.tool_key and status.tool_key then
            project_part = project_part .. " [" .. status.tool_key .. "]"
        end
        local marker = self:_status_marker(status.status)
        parts[#parts + 1] = marker .. self:_with_icon("project", project_part)
    elseif self._show.tool_key and status.tool_key then
        parts[#parts + 1] = self:_with_icon("tool_key", "[" .. status.tool_key .. "]")
    end

    -- Profile key (full, not shown by default)
    if self._show.profile_key and status.profile_key then
        parts[#parts + 1] = self:_with_icon("profile_key", status.profile_key)
    end

    -- Status (not shown by default)
    if self._show.status and status.status then
        parts[#parts + 1] = status.status
    end

    return table.concat(parts, self.options.join)
end

return M
