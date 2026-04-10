--- loomtest/explorer.lua — Test explorer UI.
---
--- Side panel showing tests grouped by target → suite → test.
--- Uses Snacks.win for the window.

local M = {}

--- @type snacks.win|nil
local _win = nil
--- @type number|nil
local _bufnr = nil
--- @type number namespace for highlights
local _ns = vim.api.nvim_create_namespace("loomtest_explorer")

--- @type string|nil selected test ID for output viewing
local _selected_id = nil

local STATUS_MARKERS = {
    passed  = { icon = "✔", hl = "DiagnosticOk" },
    failed  = { icon = "✗", hl = "DiagnosticError" },
    skipped = { icon = "⊘", hl = "DiagnosticWarn" },
    errored = { icon = "!", hl = "DiagnosticError" },
    running = { icon = "⠋", hl = "DiagnosticInfo" },
}

--- Build the tree structure from flat test nodes.
--- Groups by target → suite → test.
--- @return table[] lines, table[] highlights, table[] line_data
local function build_tree()
    local loomtest = require("loomtest")
    local nodes = loomtest.nodes()
    local config = loomtest.config()

    local lines = {}
    local highlights = {}
    local line_data = {}  -- line_num → { node, adapter }

    -- Build header
    local adapter = loomtest.adapters()[1]
    local desc = adapter and adapter.description() or nil
    local counts = { total = 0, passed = 0, failed = 0, skipped = 0, unknown = 0, running = 0 }
    for _, node in ipairs(nodes) do
        if node.type == "test" then
            counts.total = counts.total + 1
            local s = node.status or "unknown"
            if s == "errored" then s = "failed" end
            counts[s] = (counts[s] or 0) + 1
        end
    end

    local header = ""
    if desc then header = desc .. "  " end
    header = header .. "✔ " .. counts.passed .. "  ✗ " .. counts.failed
    if counts.skipped > 0 then header = header .. "  ⊘ " .. counts.skipped end
    if counts.running > 0 then header = header .. "  ⠋ " .. counts.running end
    header = header .. "  ○ " .. counts.unknown
    lines[#lines + 1] = header
    highlights[#highlights + 1] = { line = #lines, col_start = 0, col_end = #header, hl_group = "Comment" }
    lines[#lines + 1] = ""

    -- Build parent → children map
    local children_of = {}
    local top_level = {}
    for _, node in ipairs(nodes) do
        if node.parent then
            children_of[node.parent] = children_of[node.parent] or {}
            children_of[node.parent][#children_of[node.parent] + 1] = node
        else
            top_level[#top_level + 1] = node
        end
    end

    -- Render a node recursively
    local function render_node(node, indent)
        local kids = children_of[node.id]
        local marker = STATUS_MARKERS[node.status]
        local icon = marker and marker.icon or "○"
        local hl = marker and marker.hl or "Comment"

        local prefix = string.rep("  ", indent)
        local fold_char = ""
        if kids and #kids > 0 then
            fold_char = "▼ "
        end

        -- Build display line
        local display = prefix .. fold_char .. icon .. " " .. node.name

        -- Add error info for failed tests
        if node.status == "failed" and node.message then
            local short_msg = node.message:gsub("\n.*", ""):sub(1, 50)
            display = display .. "  — " .. short_msg
        end

        -- Add duration
        if node.duration then
            local dur
            if node.duration < 1000 then
                dur = string.format("%dms", node.duration)
            else
                dur = string.format("%.1fs", node.duration / 1000)
            end
            display = display .. "  " .. dur
        end

        -- Filter
        if not config.show_passed and node.status == "passed" and node.type == "test" then
            return
        end

        lines[#lines + 1] = display
        line_data[#lines] = node
        highlights[#highlights + 1] = {
            line = #lines,
            col_start = #prefix + #fold_char,
            col_end = #prefix + #fold_char + #icon,
            hl_group = hl,
        }

        -- Render children
        if kids then
            for _, child in ipairs(kids) do
                render_node(child, indent + 1)
            end
        end
    end

    for _, node in ipairs(top_level) do
        render_node(node, 0)
    end

    return lines, highlights, line_data
end

--- Render the explorer buffer.
function M.refresh()
    if not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then return end

    local lines, highlights, line_data = build_tree()

    vim.bo[_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(_bufnr, 0, -1, false, lines)
    vim.bo[_bufnr].modifiable = false

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(_bufnr, _ns, 0, -1)
    for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight,
            _bufnr, _ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end

    -- Store line data for keybinding handlers
    vim.b[_bufnr]._loomtest_line_data = line_data
end

--- Get the test node at the current cursor line.
--- @return loomtest.TestNode|nil
local function node_at_cursor()
    if not _win or not _bufnr then return nil end
    local win = type(_win) == "table" and _win.win or nil
    if not win or not vim.api.nvim_win_is_valid(win) then return nil end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_data = vim.b[_bufnr]._loomtest_line_data
    if line_data then
        return line_data[cursor[1]]
    end
    return nil
end

--- Open the explorer panel.
function M.open()
    if M.is_open() then
        M.refresh()
        return
    end

    local loomtest = require("loomtest")
    local config = loomtest.config()

    -- Create buffer
    _bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[_bufnr].buftype = "nofile"
    vim.bo[_bufnr].bufhidden = "wipe"
    vim.bo[_bufnr].swapfile = false
    vim.bo[_bufnr].filetype = "loomtest"
    vim.bo[_bufnr].modifiable = false

    -- Build Snacks.win config
    local win_config = {
        buf = _bufnr,
        enter = true,
        width = config.size,
        position = config.position,
        border = "rounded",
        title = " Tests ",
        title_pos = "center",
        wo = {
            number = false,
            relativenumber = false,
            signcolumn = "no",
            foldcolumn = "0",
            wrap = false,
            cursorline = true,
        },
        keys = {
            q = "close",
            ["<CR>"] = function()
                local node = node_at_cursor()
                if node and node.runnable then
                    loomtest.run(node.id)
                end
            end,
            r = function()
                local node = node_at_cursor()
                if node and node.runnable then
                    loomtest.run(node.id)
                end
            end,
            R = function() loomtest.run_all() end,
            o = function()
                local node = node_at_cursor()
                if node and node.file and node.line then
                    vim.cmd("wincmd p")
                    vim.cmd("edit " .. vim.fn.fnameescape(node.file))
                    vim.api.nvim_win_set_cursor(0, { node.line, 0 })
                end
            end,
            e = function()
                local node = node_at_cursor()
                if node and node._errors and #node._errors > 0 then
                    local err = node._errors[1]
                    if err.file and err.line then
                        vim.cmd("wincmd p")
                        vim.cmd("edit " .. vim.fn.fnameescape(err.file))
                        vim.api.nvim_win_set_cursor(0, { err.line, 0 })
                    end
                end
            end,
            d = function()
                local node = node_at_cursor()
                if node then
                    _selected_id = node.id
                    M.show_output()
                end
            end,
            g = function() loomtest.refresh() end,
            p = function()
                config.show_passed = not config.show_passed
                M.refresh()
            end,
        },
        on_close = function()
            _win = nil
            _bufnr = nil
        end,
    }

    _win = Snacks.win(win_config)

    -- Discover tests if not done yet
    if #loomtest.nodes() == 0 then
        loomtest.discover(function()
            M.refresh()
        end)
    else
        M.refresh()
    end
end

--- Close the explorer panel.
function M.close()
    if _win then
        if type(_win) == "table" and _win.close then
            _win:close()
        end
        _win = nil
        _bufnr = nil
    end
end

--- Check if the explorer is open.
--- @return boolean
function M.is_open()
    return _win ~= nil and _bufnr ~= nil and vim.api.nvim_buf_is_valid(_bufnr)
end

--- Toggle the explorer panel.
function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

--- Show test output in a floating window.
function M.show_output()
    local loomtest = require("loomtest")
    local node

    if _selected_id then
        node = loomtest.get_node(_selected_id)
    end

    -- Fallback: find last failed or most recently run test
    if not node then
        for _, n in ipairs(loomtest.nodes()) do
            if n.status == "failed" and n._output then
                node = n
                break
            end
        end
    end
    if not node then
        local runner = require("loomtest.runner")
        local output = runner.last_output()
        if output then
            M._show_output_float("Last test run", output, {})
            return
        end
        vim.notify("loomtest: no test output available", vim.log.levels.INFO)
        return
    end

    local title = node.name .. " (" .. (node.status or "unknown") .. ")"
    local output = node._output or node.message or "No output"
    M._show_output_float(title, output, node._errors or {})
end

--- Display output in a floating window.
--- @param title string window title
--- @param output string output text
--- @param errors loomtest.TestError[] error locations
function M._show_output_float(title, output, errors)
    local lines = vim.split(output, "\n")

    -- Add error summary at top
    if #errors > 0 then
        local err_lines = { "Errors:", "" }
        for _, err in ipairs(errors) do
            local loc = ""
            if err.file and err.line then
                loc = vim.fn.fnamemodify(err.file, ":t") .. ":" .. err.line .. " "
            end
            err_lines[#err_lines + 1] = "  " .. loc .. err.message
        end
        err_lines[#err_lines + 1] = ""
        err_lines[#err_lines + 1] = "Output:"
        err_lines[#err_lines + 1] = ""
        for _, l in ipairs(lines) do
            err_lines[#err_lines + 1] = l
        end
        lines = err_lines
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    Snacks.win({
        buf = buf,
        enter = true,
        position = "float",
        width = 0.8,
        height = 0.7,
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
        keys = { q = "close" },
        wo = {
            number = false,
            relativenumber = false,
            wrap = true,
        },
    })
end

return M
