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
--- status-page Diagnostics section. Coloured with DiagnosticWarn's /
--- DiagnosticError's foreground. Drop "diagnostics" from `show` to disable.
---
--- Marker colours: each marker takes only the FOREGROUND of its group
--- (DiagnosticOk/Warn/Error, Comment) through lualine highlights made with
--- `create_hl`; lualine fills the background from the section, and the text
--- after a marker switches back to the section highlight
--- (`get_default_hl`), so markers fit any section of a statusline or winbar
--- (spec/ui.md §3). Raw `%#Group#…%*` escapes would reset to
--- StatusLine/WinBar and carry the group's own (usually absent) background.
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
---     starts when a render shows a running state and stops once renders
---     have shown none for a while, so there's zero refresh cost while the
---     workspace is idle. `status_icons = false` disables both icons and
---     the timer.
---
--- Data: `lw.buf_status()`, which reads the editor's views
--- (`loomworks.view.Header/1`, `loomworks.view.ProjectsIndex/1`; spec
--- §19.13 "Two sources, one shape"): the daemon's while the editor is
--- subscribed, otherwise built in-process. The component itself never
--- reaches into the workspace or its events.

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
    mixed            = "\u{25cb}",  -- ○ (aggregate when configs disagree; amber)
}

--- Highlight group per state. Maps to standard Diagnostic groups so
--- the marker reads independently of any surrounding text colour. Only the
--- group's foreground is used (see `_marker_hl`).
local STATUS_HL = {
    built            = "DiagnosticOk",
    -- Red: an unconfigured active unit means its language server is withheld
    -- (spec §9.8), not a neutral resting state. Mixed is amber — part of the
    -- profile is usable, part is not (spec/ui.md §3).
    unconfigured     = "DiagnosticError",
    mixed            = "DiagnosticWarn",
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

--- How long the timer keeps redrawing after the last render that showed a
--- running state (covers lualine refreshing on its own schedule).
local IDLE_STOP_MS = 2000

local _uv = vim.uv or vim.loop
local _timer = nil
local _last_running_ms = nil

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

local function now_ms() return _uv.hrtime() / 1e6 end

--- Note that a render showed a running state and start the timer if it
--- isn't running. The timer stops by itself once no render has shown one
--- for IDLE_STOP_MS.
local function note_running()
    _last_running_ms = now_ms()
    if _timer then return end
    _timer = _uv.new_timer()
    -- Manual statusline refresh — lualine's own timer is too slow for
    -- spinner animation (1s default). We could lower it globally but
    -- that affects every other component too; cheaper to just kick
    -- redrawstatus ~12 times per second only while tasks are active.
    _timer:start(0, SPINNER_INTERVAL_MS, vim.schedule_wrap(function()
        if _last_running_ms and now_ms() - _last_running_ms <= IDLE_STOP_MS then
            pcall(vim.cmd, "redrawstatus")
        else
            stop_timer()
        end
    end))
end

-- ---------------------------------------------------------------------------
-- Marker highlights
-- ---------------------------------------------------------------------------

--- Every group a marker can use (STATUS_HL values, the `Comment` fallback,
--- and the diagnostics indicator's groups).
local MARKER_GROUPS = { "DiagnosticOk", "DiagnosticWarn", "DiagnosticError", "Comment" }
M._MARKER_GROUPS = MARKER_GROUPS

--- The foreground of `group` as "#rrggbb", or nil when it has none.
--- @param group string
--- @return string|nil
local function group_fg(group)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if not ok or type(hl) ~= "table" or not hl.fg then return nil end
    return string.format("#%06x", hl.fg)
end
M._group_fg = group_fg

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

    -- One lualine highlight per marker group, created up front (like
    -- lualine's diagnostics component). `color` is a function so the
    -- group's current fg is read on every redraw; lualine also re-creates
    -- components on ColorScheme.
    self._marker_hls = {}
    for _, group in ipairs(MARKER_GROUPS) do
        self._marker_hls[group] = self:create_hl(function()
            local fg = group_fg(group)
            return fg and { fg = fg } or {}
        end, group)
    end
end

--- Make workspace data inert in a statusline string: remove control
--- characters and double every `%` so a name from a (possibly cloned)
--- loomworks.json cannot inject statusline items, highlight groups or
--- expressions (spec/ui.md §3). Applied to data only — never to the
--- component's own highlight escapes, icons or join string.
--- @param s any
--- @return string
local function inert(s)
    s = tostring(s):gsub("%c", "")
    return (s:gsub("%%", "%%%%"))
end
M._inert = inert

--- Prepend the configured icon (if any) to a field's rendered value.
--- @param field string
--- @param value string
--- @return string
function M:_with_icon(field, value)
    local icon = self._icons[field]
    if not icon then return value end
    return icon .. value
end

--- Wrap `text` in the lualine highlight for `group`'s foreground, then
--- return to the section's own highlight.
--- @param group string one of MARKER_GROUPS
--- @param text string
--- @return string
function M:_marker_hl(group, text)
    return self:format_hl(self._marker_hls[group]) .. text .. self:get_default_hl()
end

--- Render a status icon (spinner frame for running states; mapped
--- glyph otherwise) in its group's colour. Returns the empty string for
--- unknown / nil states so callers can append unconditionally.
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
    if RUNNING_STATES[state] then note_running() end
    return self:_marker_hl(hl, glyph) .. " "
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
    -- segment overflows / scrolls.
    if self._show.diagnostics and status.diagnostic_severity then
        local hl = status.diagnostic_severity == "error"
            and "DiagnosticError" or "DiagnosticWarn"
        local icon = status.diagnostic_severity == "error"
            and "\u{2717}" or "\u{26a0}"   -- ✗ or ⚠
        parts[#parts + 1] = self:_marker_hl(hl, icon)
    end

    -- Set name: "debug". Status marker (from profile_state) precedes
    -- the field icon so the order reads:
    --   <status icon> <profile icon> <set name>.
    if self._show.set_name and status.set_name then
        local marker = self:_status_marker(status.profile_state)
        parts[#parts + 1] = marker .. self:_with_icon("set_name", inert(status.set_name))
    end

    -- Project and configuration: "App/Debug" or just "App"
    local project_part
    if self._show.project and status.project then
        if self._show.configuration and status.configuration then
            project_part = inert(status.project) .. "/" .. inert(status.configuration)
        else
            project_part = inert(status.project)
        end
    elseif self._show.configuration and status.configuration then
        project_part = inert(status.configuration)
    end

    -- Tool key in brackets appended to project: "App/Debug [ninja-gcc-12]"
    if project_part then
        if self._show.tool_key and status.tool_key then
            project_part = project_part .. " [" .. inert(status.tool_key) .. "]"
        end
        local marker = self:_status_marker(status.status)
        parts[#parts + 1] = marker .. self:_with_icon("project", project_part)
    elseif self._show.tool_key and status.tool_key then
        parts[#parts + 1] = self:_with_icon("tool_key", "[" .. inert(status.tool_key) .. "]")
    end

    -- Profile key (full, not shown by default)
    if self._show.profile_key and status.profile_key then
        parts[#parts + 1] = self:_with_icon("profile_key", inert(status.profile_key))
    end

    -- Status (not shown by default)
    if self._show.status and status.status then
        parts[#parts + 1] = inert(status.status)
    end

    return table.concat(parts, self.options.join)
end

return M
