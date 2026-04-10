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
--- @type table<string, boolean> fold state: node_id → collapsed
local _folds = {}
--- @type string|nil selected test ID for output viewing
local _selected_id = nil

local STATUS_ICONS = {
    passed  = { icon = "✔", hl = "DiagnosticOk" },
    failed  = { icon = "✗", hl = "DiagnosticError" },
    skipped = { icon = "⊘", hl = "DiagnosticWarn" },
    errored = { icon = "!", hl = "DiagnosticError" },
    running = { icon = "↻", hl = "DiagnosticInfo" },
}

--- Infer suite grouping from flat test nodes.
--- Tests with names like "Suite.Test" get grouped under a synthetic suite node.
--- Returns a new node list with suite nodes inserted.
--- @param nodes loomtest.TestNode[]
--- @return loomtest.TestNode[]
local function build_grouped_nodes(nodes)
    local result = {}
    -- Track which targets have children and what suites exist
    local suites_by_target = {} -- target_id → { suite_name → { tests } }
    local targets = {}
    local target_order = {}

    for _, node in ipairs(nodes) do
        if not node.parent then
            targets[node.id] = node
            target_order[#target_order + 1] = node.id
        end
    end

    for _, node in ipairs(nodes) do
        if node.parent and targets[node.parent] then
            -- Infer suite from test name: "Suite.Test" → suite "Suite"
            local suite_name = node.name:match("^([^%.]+)%.")
            if suite_name then
                local target_id = node.parent
                suites_by_target[target_id] = suites_by_target[target_id] or {}
                suites_by_target[target_id][suite_name] = suites_by_target[target_id][suite_name] or {}
                local suite_tests = suites_by_target[target_id][suite_name]
                suite_tests[#suite_tests + 1] = node
            end
        end
    end

    -- Build the grouped list
    for _, target_id in ipairs(target_order) do
        local target = targets[target_id]
        result[#result + 1] = target

        local suites = suites_by_target[target_id]
        if suites then
            -- Sort suite names
            local suite_names = {}
            for name in pairs(suites) do
                suite_names[#suite_names + 1] = name
            end
            table.sort(suite_names)

            for _, suite_name in ipairs(suite_names) do
                local suite_id = target_id .. "::" .. suite_name
                -- Compute aggregate status
                local suite_status = nil
                local tests = suites[suite_name]
                for _, t in ipairs(tests) do
                    if t.status == "failed" or t.status == "errored" then
                        suite_status = "failed"
                    elseif t.status == "running" then
                        suite_status = suite_status or "running"
                    elseif t.status == "passed" and not suite_status then
                        suite_status = "passed"
                    elseif t.status == "skipped" and not suite_status then
                        suite_status = "skipped"
                    end
                end

                result[#result + 1] = {
                    id = suite_id,
                    name = suite_name,
                    type = "suite",
                    parent = target_id,
                    runnable = true,
                    status = suite_status,
                    _synthetic = true,
                    _test_count = #tests,
                }

                -- Add tests under suite, stripping suite prefix from name
                for _, test in ipairs(tests) do
                    result[#result + 1] = {
                        id = test.id,
                        name = test.name:match("^[^%.]+%.(.+)$") or test.name,
                        type = "test",
                        parent = suite_id,
                        file = test.file,
                        line = test.line,
                        runnable = test.runnable,
                        status = test.status,
                        message = test.message,
                        duration = test.duration,
                        _output = test._output,
                        _errors = test._errors,
                    }
                end
            end
        end
    end

    return result
end

--- Build the rendered tree lines from grouped nodes.
--- @return table[] lines, table[] highlights, table[] line_data
local function build_tree()
    local loomtest = require("loomtest")
    local raw_nodes = loomtest.nodes()
    local config = loomtest.config()

    local grouped = build_grouped_nodes(raw_nodes)

    local lines = {}
    local highlights = {}
    local line_data = {}

    -- Header
    local adapter = loomtest.adapters()[1]
    local desc = adapter and adapter.description() or nil
    local counts = { passed = 0, failed = 0, skipped = 0, unknown = 0, running = 0 }
    for _, node in ipairs(grouped) do
        if node.type == "test" then
            local s = node.status or "unknown"
            if s == "errored" then s = "failed" end
            counts[s] = (counts[s] or 0) + 1
        end
    end

    local header = ""
    if desc then header = desc .. "  " end
    header = header .. "✔ " .. counts.passed .. "  ✗ " .. counts.failed
    if counts.skipped > 0 then header = header .. "  ⊘ " .. counts.skipped end
    if counts.running > 0 then header = header .. "  ↻ " .. counts.running end
    header = header .. "  ○ " .. counts.unknown
    lines[#lines + 1] = header
    highlights[#highlights + 1] = { line = #lines, col_start = 0, col_end = #header, hl_group = "Comment" }
    lines[#lines + 1] = ""

    -- Build parent → children map
    local children_of = {}
    local top_level = {}
    for _, node in ipairs(grouped) do
        if node.parent then
            children_of[node.parent] = children_of[node.parent] or {}
            children_of[node.parent][#children_of[node.parent] + 1] = node
        else
            top_level[#top_level + 1] = node
        end
    end

    local function render_node(node, indent)
        local kids = children_of[node.id]
        local has_kids = kids and #kids > 0
        local collapsed = _folds[node.id]

        local si = STATUS_ICONS[node.status]
        local icon = si and si.icon or "○"
        local hl = si and si.hl or "Comment"

        local prefix = string.rep("  ", indent)
        local fold_char = ""
        if has_kids then
            fold_char = collapsed and "▶ " or "▼ "
        else
            fold_char = "  "
        end

        -- Build display
        local display = prefix .. fold_char .. icon .. " " .. node.name

        -- Suite: show test count
        if node.type == "suite" and node._test_count then
            display = display .. " (" .. node._test_count .. ")"
        end

        -- Failed: show inline error
        if node.status == "failed" and node.message then
            local short_msg = node.message:gsub("\n.*", ""):sub(1, 50)
            display = display .. "  — " .. short_msg
        end

        -- Duration
        if node.duration then
            local dur
            if node.duration < 1000 then
                dur = string.format("%dms", node.duration)
            else
                dur = string.format("%.1fs", node.duration / 1000)
            end
            display = display .. "  " .. dur
        end

        -- Filter passed
        if not config.show_passed and node.status == "passed" and node.type == "test" then
            return
        end

        lines[#lines + 1] = display
        line_data[#lines] = node
        -- Highlight the status icon
        local icon_start = #prefix + #fold_char
        highlights[#highlights + 1] = {
            line = #lines,
            col_start = icon_start,
            col_end = icon_start + #icon,
            hl_group = hl,
        }

        -- Render children (unless collapsed)
        if has_kids and not collapsed then
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

--- Toggle fold on the node at cursor.
local function toggle_fold()
    local node = node_at_cursor()
    if not node then return end
    _folds[node.id] = not _folds[node.id]
    M.refresh()
end

--- Open the explorer panel.
function M.open()
    if M.is_open() then
        M.refresh()
        return
    end

    local loomtest = require("loomtest")
    local config = loomtest.config()

    _bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[_bufnr].buftype = "nofile"
    vim.bo[_bufnr].bufhidden = "wipe"
    vim.bo[_bufnr].swapfile = false
    vim.bo[_bufnr].filetype = "loomtest"
    vim.bo[_bufnr].modifiable = false

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
            ["<Tab>"] = toggle_fold,
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
function M._show_output_float(title, output, errors)
    local lines = vim.split(output, "\n")

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
