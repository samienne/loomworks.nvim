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
--- @type table<string, string> fold cursor memory: fold_node_id → cursor_node_id
local _fold_cursor = {}
--- @type string|nil selected test ID for output viewing
local _selected_id = nil
--- @type table[] current line_data for cursor operations
local _line_data = {}

local STATUS_ICONS = {
    passed  = { icon = "✔", hl = "DiagnosticOk" },
    failed  = { icon = "✗", hl = "DiagnosticError" },
    skipped = { icon = "⊘", hl = "DiagnosticWarn" },
    errored = { icon = "!", hl = "DiagnosticError" },
    running = { icon = "↻", hl = "DiagnosticInfo" },
}

--- Infer suite grouping from flat test nodes.
--- @param nodes loomtest.TestNode[]
--- @return loomtest.TestNode[]
local function build_grouped_nodes(nodes)
    local result = {}
    local suites_by_target = {}
    local targets = {}
    local target_order = {}

    for _, node in ipairs(nodes) do
        if not node.parent then
            targets[node.id] = node
            target_order[#target_order + 1] = node.id
        end
    end

    local seen_ids = {}
    for _, node in ipairs(nodes) do
        if node.parent and targets[node.parent] then
            -- Deduplicate: skip if we've already seen this test ID
            if seen_ids[node.id] then goto continue end
            seen_ids[node.id] = true

            local suite_name = node.name:match("^([^%.]+)%.")
            if suite_name then
                local target_id = node.parent
                suites_by_target[target_id] = suites_by_target[target_id] or {}
                suites_by_target[target_id][suite_name] = suites_by_target[target_id][suite_name] or {}
                local suite_tests = suites_by_target[target_id][suite_name]
                suite_tests[#suite_tests + 1] = node
            end
            ::continue::
        end
    end

    for _, target_id in ipairs(target_order) do
        local target = targets[target_id]
        result[#result + 1] = target

        local suites = suites_by_target[target_id]
        if suites then
            local suite_names = {}
            for name in pairs(suites) do
                suite_names[#suite_names + 1] = name
            end
            table.sort(suite_names)

            for _, suite_name in ipairs(suite_names) do
                local suite_id = target_id .. "::" .. suite_name
                local suite_status = nil
                local tests = suites[suite_name]
                for _, t in ipairs(tests) do
                    if t.status == "failed" or t.status == "errored" then
                        suite_status = "failed"
                    elseif t.status == "running" and suite_status ~= "failed" then
                        suite_status = "running"
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

--- Build the rendered tree.
--- @return table[] lines, table[] highlights, table[] line_data
local function build_tree()
    local loomtest = require("loomtest")
    local raw_nodes = loomtest.nodes()
    local config = loomtest.config()
    local grouped = build_grouped_nodes(raw_nodes)

    local lines = {}
    local highlights = {}
    local line_data = {}

    -- Header line 1: adapter description
    local adapter = loomtest.adapters()[1]
    local desc = adapter and adapter.description() or "Tests"
    lines[#lines + 1] = " " .. desc
    highlights[#highlights + 1] = { line = #lines, col_start = 0, col_end = #lines[#lines], hl_group = "Title" }

    -- Header line 2: counts
    local counts = { passed = 0, failed = 0, skipped = 0, unknown = 0, running = 0 }
    for _, node in ipairs(grouped) do
        if node.type == "test" then
            local s = node.status or "unknown"
            if s == "errored" then s = "failed" end
            counts[s] = (counts[s] or 0) + 1
        end
    end
    local count_parts = {}
    if counts.passed > 0 then count_parts[#count_parts + 1] = "✔ " .. counts.passed end
    if counts.failed > 0 then count_parts[#count_parts + 1] = "✗ " .. counts.failed end
    if counts.skipped > 0 then count_parts[#count_parts + 1] = "⊘ " .. counts.skipped end
    if counts.running > 0 then count_parts[#count_parts + 1] = "↻ " .. counts.running end
    count_parts[#count_parts + 1] = "○ " .. counts.unknown
    lines[#lines + 1] = " " .. table.concat(count_parts, "  ")
    highlights[#highlights + 1] = { line = #lines, col_start = 0, col_end = #lines[#lines], hl_group = "Comment" }

    -- Blank separator
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
        local fold_char
        if has_kids then
            fold_char = collapsed and "▶ " or "▼ "
        else
            fold_char = "  "
        end

        local display = prefix .. fold_char .. icon .. " " .. node.name

        -- Suite: show count
        if node._test_count then
            display = display .. " (" .. node._test_count .. ")"
        end

        -- Failed: inline error
        if node.status == "failed" and node.message then
            local short_msg = node.message:gsub("\n.*", ""):sub(1, 40)
            display = display .. "  — " .. short_msg
        end

        -- Duration
        if node.duration then
            if node.duration < 1000 then
                display = display .. "  " .. string.format("%dms", node.duration)
            else
                display = display .. "  " .. string.format("%.1fs", node.duration / 1000)
            end
        end

        -- Filter passed
        if not config.show_passed and node.status == "passed" and node.type == "test" then
            return
        end

        lines[#lines + 1] = display
        line_data[#lines] = node

        -- Highlight status icon
        local icon_start = #prefix + #fold_char
        highlights[#highlights + 1] = {
            line = #lines,
            col_start = icon_start,
            col_end = icon_start + #icon,
            hl_group = hl,
        }
        -- Highlight fold char
        if has_kids then
            highlights[#highlights + 1] = {
                line = #lines,
                col_start = #prefix,
                col_end = #prefix + #fold_char - 1,
                hl_group = "NonText",
            }
        end
        -- Highlight name for targets/suites
        if node.type == "target" then
            highlights[#highlights + 1] = {
                line = #lines,
                col_start = icon_start + #icon + 1,
                col_end = #display,
                hl_group = "Function",
            }
        elseif node.type == "suite" then
            highlights[#highlights + 1] = {
                line = #lines,
                col_start = icon_start + #icon + 1,
                col_end = icon_start + #icon + 1 + #node.name,
                hl_group = "Type",
            }
        end

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

--- Find the nearest actionable line to the given line.
--- @param target_line number
--- @return number|nil
local function nearest_actionable(target_line)
    if _line_data[target_line] then return target_line end
    local total = #_line_data
    for offset = 1, total do
        local down = target_line + offset
        local up = target_line - offset
        if down <= total and _line_data[down] then return down end
        if up >= 1 and _line_data[up] then return up end
    end
    return nil
end

--- Snap cursor to nearest actionable line.
local function snap_cursor()
    if not _win or not _bufnr then return end
    local win = type(_win) == "table" and _win.win or nil
    if not win or not vim.api.nvim_win_is_valid(win) then return end

    local cursor = vim.api.nvim_win_get_cursor(win)
    local target = nearest_actionable(cursor[1])
    if target and target ~= cursor[1] then
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
end

--- Render the explorer buffer.
function M.refresh()
    if not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then return end

    local win = _win and type(_win) == "table" and _win.win or nil
    local saved_cursor = win and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_cursor(win) or nil

    local lines, highlights, line_data = build_tree()
    _line_data = line_data

    vim.bo[_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(_bufnr, 0, -1, false, lines)
    vim.bo[_bufnr].modifiable = false

    vim.api.nvim_buf_clear_namespace(_bufnr, _ns, 0, -1)
    for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight,
            _bufnr, _ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end

    -- Restore cursor
    if saved_cursor and win and vim.api.nvim_win_is_valid(win) then
        local line = math.min(saved_cursor[1], #lines)
        pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    end
    snap_cursor()
end

--- Get the test node at the current cursor line.
--- @return loomtest.TestNode|nil
local function node_at_cursor()
    if not _win or not _bufnr then return nil end
    local win = type(_win) == "table" and _win.win or nil
    if not win or not vim.api.nvim_win_is_valid(win) then return nil end

    local cursor = vim.api.nvim_win_get_cursor(win)
    return _line_data[cursor[1]]
end

--- Find the line number of a node by ID in current line_data.
--- @param node_id string
--- @return number|nil
local function find_line_for_node(node_id)
    for line, node in pairs(_line_data) do
        if node and node.id == node_id then return line end
    end
    return nil
end

--- Close fold (h key): fold current node and move cursor to it.
--- On a leaf or already-collapsed node, moves to parent and folds it.
--- Saves the cursor node so l can restore position.
local function fold_close()
    local node = node_at_cursor()
    if not node then return end
    local win = _win and type(_win) == "table" and _win.win or nil
    if not win then return end

    -- If on an expanded foldable node, collapse it
    if not _folds[node.id] and (node.type == "target" or node.type == "suite") then
        _fold_cursor[node.id] = node.id
        _folds[node.id] = true
        M.refresh()
        return
    end

    -- Otherwise, move to parent and collapse the parent
    if node.parent then
        _fold_cursor[node.parent] = node.id
        _folds[node.parent] = true
        M.refresh()
        -- Move cursor to the parent node
        local parent_line = find_line_for_node(node.parent)
        if parent_line then
            pcall(vim.api.nvim_win_set_cursor, win, { parent_line, 0 })
        end
    end
end

--- Open fold (l key): expand current node and restore saved cursor.
local function fold_open()
    local node = node_at_cursor()
    if not node then return end

    if _folds[node.id] then
        local saved_node_id = _fold_cursor[node.id]
        _folds[node.id] = nil
        _fold_cursor[node.id] = nil
        M.refresh()
        -- Restore cursor to the saved node
        if saved_node_id then
            local target_line = find_line_for_node(saved_node_id)
            if target_line then
                local win = _win and type(_win) == "table" and _win.win or nil
                if win then
                    pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
                end
            end
        end
    end
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

    local win_config = vim.tbl_deep_extend("force", {
        position = config.position,
        width = config.size,
        border = "rounded",
        title = " Tests ",
        title_pos = "center",
    }, config.win or {})

    -- Non-overridable fields
    win_config.buf = _bufnr
    win_config.enter = true
    win_config.wo = vim.tbl_extend("force", {
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        wrap = false,
        cursorline = true,
    }, win_config.wo or {})
    win_config.keys = {
        q = "close",
        ["<CR>"] = function()
            local node = node_at_cursor()
            if node and node.runnable then
                loomtest.run(node.id, node.type)
            end
        end,
        r = function()
            local node = node_at_cursor()
            if node and node.runnable then
                loomtest.run(node.id, node.type)
            end
        end,
        R = function() loomtest.run_all() end,
        h = fold_close,
        l = fold_open,
        ["<Tab>"] = function()
            local node = node_at_cursor()
            if not node then return end
            if _folds[node.id] then fold_open() else fold_close() end
        end,
        i = function()
            -- Jump to test source in the previous window
            local node = node_at_cursor()
            if not node or not node.file or not node.line then return end
            -- Find a non-explorer window to open in
            local target_win = nil
            for _, w in ipairs(vim.api.nvim_list_wins()) do
                local buf = vim.api.nvim_win_get_buf(w)
                if buf ~= _bufnr and vim.bo[buf].buftype == "" then
                    target_win = w
                    break
                end
            end
            if not target_win then
                vim.cmd("wincmd p")
                target_win = vim.api.nvim_get_current_win()
            else
                vim.api.nvim_set_current_win(target_win)
            end
            vim.cmd("edit " .. vim.fn.fnameescape(node.file))
            pcall(vim.api.nvim_win_set_cursor, target_win, { node.line, 0 })
        end,
        e = function()
            -- Jump to first error location
            local node = node_at_cursor()
            if not node or not node._errors or #node._errors == 0 then return end
            local err = node._errors[1]
            if not err.file or not err.line then return end
            local target_win = nil
            for _, w in ipairs(vim.api.nvim_list_wins()) do
                local buf = vim.api.nvim_win_get_buf(w)
                if buf ~= _bufnr and vim.bo[buf].buftype == "" then
                    target_win = w
                    break
                end
            end
            if not target_win then
                vim.cmd("wincmd p")
                target_win = vim.api.nvim_get_current_win()
            else
                vim.api.nvim_set_current_win(target_win)
            end
            vim.cmd("edit " .. vim.fn.fnameescape(err.file))
            pcall(vim.api.nvim_win_set_cursor, target_win, { err.line, 0 })
        end,
        o = function()
            -- Show test output — look up canonical node for output data
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
    }
    win_config.on_close = function()
        _win = nil
        _bufnr = nil
    end

    _win = Snacks.win(win_config)

    -- Lock cursor to actionable lines
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = _bufnr,
        callback = snap_cursor,
    })

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
    if M.is_open() then M.close() else M.open() end
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
                node = n; break
            end
        end
    end

    if not node or not node._output then
        vim.notify("loomtest: no test output available", vim.log.levels.INFO)
        return
    end

    local title = node.name .. " (" .. (node.status or "unknown") .. ")"
    M._show_output_float(title, node._output, node._errors or {})
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
        wo = { number = false, relativenumber = false, wrap = true },
    })
end

return M
