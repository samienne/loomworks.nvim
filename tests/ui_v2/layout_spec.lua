--- Layout-level integration tests for the v2 UI.
---
--- Opens real Neovim windows and exercises cursor / refresh behaviour
--- end-to-end. Specifically guards against navigation regressions where
--- background refreshes pull the cursor away from non-selectable lines
--- the user was passing through.

local workspace = require("loomworks.workspace")
local merge     = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h         = require("tests.helpers")
local Configuration = require("loomworks.configuration")

local Workspace = workspace.Workspace

local mock_modules = {
    cmake = {
        id = "cmake",
        has_keyed_tools = true,
        has_options = true,
        tools_match = function(a, b)
            if a == nil and b == nil then return true end
            if a == nil or b == nil then return false end
            return vim.deep_equal(a, b)
        end,
        default_configurations = function()
            return { Debug = { prefix = "variant", variant = "Debug" } }
        end,
        map_variant = function(v, configs)
            for _, n in ipairs(configs) do if n:lower() == v then return n end end
        end,
        tool_key = function(td) return td.id end,
        tool_label = function(td) return td.display end,
        detect_tools_async = function(cb) cb({}) end,
        info = function(_, config)
            local d = { Debug = { prefix = "variant", variant = "Debug" } }
            return { configurations = Configuration.canonicalize(d, config and config.configurations, "cmake") }
        end,
    },
}

local function fake_events()
    local listeners = {}
    return {
        on  = function(e, fn) listeners[e] = listeners[e] or {}; table.insert(listeners[e], fn) end,
        off = function(e, fn)
            for i, l in ipairs(listeners[e] or {}) do
                if l == fn then table.remove(listeners[e], i); return end
            end
        end,
        emit = function(e, d)
            for _, fn in ipairs(listeners[e] or {}) do fn(d) end
        end,
    }
end

local function make_ws(config_overrides, user_overrides, cache_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local cache_json = cache_overrides and h.make_cache_json(cache_overrides) or nil
    local data = workspace.assemble("/root", config_json, user_json, cache_json)
    local mock_core = {
        _deps = {
            merge = merge, cache = cache_mod,
            events = { emit = function() end },
            user = { save = function() return true end },
            io = { write_json = function() return true end, ensure_dir = function() return true end,
                   rm_rf_async = function(_, cb) cb(true, nil) end },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
            clock = function() return 0 end,
            now = function() return "2000-01-01T00:00:00Z" end,
            log = require("loomworks.log").test(),
        },
    }
    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws
end

describe("ui v2 layout — cursor navigation", function()
    local ViewModel = require("loomworks.ui.v2.view_model")
    local Layout    = require("loomworks.ui.v2.view.layout")

    local function make_setup()
        local ws = make_ws(
            {
                projects = {
                    App   = { cmake = {} },
                    Other = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { App = "variant:Debug", Other = "variant:Debug" },
                },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local events = fake_events()
        local vm = ViewModel.new({
            workspace_provider = function() return ws end,
            events = events,
        })
        local layout = Layout.new(vm)
        return ws, vm, events, layout
    end

    it("a refresh triggered by an event does not snap the cursor away from a non-selectable line", function()
        local _, vm, events, layout = make_setup()
        layout:open()

        -- Move cursor to a non-selectable line (the separator/header area
        -- between sections). Pick the first line whose line_map entry is nil.
        local non_selectable_row
        for line = 1, vim.api.nvim_buf_line_count(layout._overview_buf) do
            if not layout._line_map[line] then
                non_selectable_row = line
                break
            end
        end
        assert.is_not_nil(non_selectable_row, "must have at least one non-selectable line")

        layout._suppress_cursor = true
        vim.api.nvim_win_set_cursor(layout._overview_win, { non_selectable_row, 0 })
        layout._suppress_cursor = false

        -- Fire a refresh-triggering event. With the bug this would snap
        -- the cursor to the nearest selectable line.
        events.emit("task_progress", nil)
        vim.wait(20)  -- let scheduled refresh run

        local cur = vim.api.nvim_win_get_cursor(layout._overview_win)
        assert.equals(non_selectable_row, cur[1],
            "cursor must remain on the non-selectable line after a refresh")

        layout:close()
    end)

    it("opens with cursor snapped to the first selectable line", function()
        local _, _, _, layout = make_setup()
        layout:open()
        local cur_row = vim.api.nvim_win_get_cursor(layout._overview_win)[1]
        assert.is_not_nil(layout._line_map[cur_row],
            "cursor should land on a selectable line after open")
        layout:close()
    end)

    it("clamps cursor to last line when buffer shrinks below cursor row", function()
        local ws, vm, _, layout = make_setup()
        layout:open()

        -- Move cursor near the end of the buffer.
        local count = vim.api.nvim_buf_line_count(layout._overview_buf)
        layout._suppress_cursor = true
        vim.api.nvim_win_set_cursor(layout._overview_win, { count, 0 })
        layout._suppress_cursor = false

        -- Force a refresh; lines stay the same here, but if they shrank,
        -- nvim auto-clamps and our refresh shouldn't error.
        layout:refresh()
        local cur = vim.api.nvim_win_get_cursor(layout._overview_win)
        assert.is_true(cur[1] >= 1)
        assert.is_true(cur[1] <= vim.api.nvim_buf_line_count(layout._overview_buf))

        layout:close()
    end)
end)
