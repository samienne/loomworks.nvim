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

--- Status priority for parent aggregation.
--- Higher number = stronger (overrides lower).
local STATUS_PRIORITY = {
    passed  = 1,
    skipped = 2,
    pending = 3,
    running = 4,
    errored = 5,
    failed  = 5,
}

--- Compute aggregate status from children.
--- @param statuses string[] child statuses
--- @return string|nil
local function aggregate_status(statuses)
    local best = nil
    local best_pri = 0
    for _, s in ipairs(statuses) do
        local pri = STATUS_PRIORITY[s or ""] or 0
        if pri > best_pri then
            best = s
            best_pri = pri
        elseif pri == 0 and best_pri == 0 then
            best = nil
        end
    end
    return best
end

local STATUS_ICONS = {
    passed  = { icon = "✔", hl = "DiagnosticOk" },
    failed  = { icon = "✗", hl = "DiagnosticError" },
    skipped = { icon = "⊘", hl = "DiagnosticWarn" },
    errored = { icon = "!", hl = "DiagnosticError" },
    running = { icon = "↻", hl = "DiagnosticInfo" },
    pending = { icon = "◌", hl = "DiagnosticHint" },
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
                local tests = suites[suite_name]
                local child_statuses = {}
                for _, t in ipairs(tests) do
                    child_statuses[#child_statuses + 1] = t.status
                end
                local suite_status = aggregate_status(child_statuses)

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

    local adapter = loomtest.adapters()[1]
    local desc = adapter and adapter.description() or "Tests"
    lines[#lines + 1] = " " .. desc
    highlights[#highlights + 1] = { line = #lines, col_start = 0, col_end = #lines[#lines], hl_group = "Title" }

    local counts = { passed = 0, failed = 0, skipped = 0, unknown = 0, running = 0, pending = 0 }
    local total = 0
    for _, node in ipairs(grouped) do
        if node.type == "test" then
            total = total + 1
            local s = node.status or "unknown"
            if s == "errored" then s = "failed" end
            counts[s] = (counts[s] or 0) + 1
        end
    end

    -- Build colored count line: "🧪 1323  ✔ 1200  ✗ 3  ..."
    local count_line = " 🧪 " .. total
    local count_hl_line = #lines + 1
    highlights[#highlights + 1] = { line = count_hl_line, col_start = 0, col_end = #count_line, hl_group = "Comment" }

    local count_segments = {
        { icon = "✔", count = counts.passed, hl = "DiagnosticOk" },
        { icon = "✗", count = counts.failed, hl = "DiagnosticError" },
        { icon = "↻", count = counts.running + counts.pending, hl = "DiagnosticInfo" },
        { icon = "⊘", count = counts.skipped, hl = "DiagnosticWarn" },
        { icon = "○", count = counts.unknown, hl = "Comment" },
    }
    for _, seg in ipairs(count_segments) do
        do
            local part = "  " .. seg.icon .. " " .. seg.count
            local start = #count_line
            count_line = count_line .. part
            highlights[#highlights + 1] = {
                line = count_hl_line,
                col_start = start + 2,
                col_end = start + 2 + #seg.icon,
                hl_group = seg.hl,
            }
        end
    end
    lines[#lines + 1] = count_line

    lines[#lines + 1] = ""

    -- Build parent → children map and propagate status to targets
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

    for _, node in ipairs(top_level) do
        local kids = children_of[node.id]
        if kids then
            local child_statuses = {}
            for _, child in ipairs(kids) do
                child_statuses[#child_statuses + 1] = child.status
            end
            node.status = aggregate_status(child_statuses)
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

        if node._test_count then
            display = display .. " (" .. node._test_count .. ")"
        end

        if node.status == "failed" and node.message then
            local short_msg = node.message:gsub("\n.*", ""):sub(1, 40)
            display = display .. "  — " .. short_msg
        end

        if node.duration then
            if node.duration < 1000 then
                display = display .. "  " .. string.format("%dms", node.duration)
            else
                display = display .. "  " .. string.format("%.1fs", node.duration / 1000)
            end
        end

        if not config.show_passed and node.status == "passed" and node.type == "test" then
            return
        end

        lines[#lines + 1] = display
        line_data[#lines] = node

        local icon_start = #prefix + #fold_char
        highlights[#highlights + 1] = {
            line = #lines,
            col_start = icon_start,
            col_end = icon_start + #icon,
            hl_group = hl,
        }
        if has_kids then
            highlights[#highlights + 1] = {
                line = #lines,
                col_start = #prefix,
                col_end = #prefix + #fold_char - 1,
                hl_group = "NonText",
            }
        end
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
--- @param force? boolean if true, always snap even on non-move events
local function snap_cursor(force)
    if not _win or not _bufnr then return end
    local win = type(_win) == "table" and _win.win or nil
    if not win or not vim.api.nvim_win_is_valid(win) then return end

    local cursor = vim.api.nvim_win_get_cursor(win)
    if _line_data[cursor[1]] then return end -- already on actionable line

    local target = nearest_actionable(cursor[1])
    if target then
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

    if not _folds[node.id] and (node.type == "target" or node.type == "suite") then
        _fold_cursor[node.id] = node.id
        _folds[node.id] = true
        M.refresh()
        return
    end

    if node.parent then
        _fold_cursor[node.parent] = node.id
        _folds[node.parent] = true
        M.refresh()
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
        relative = "win",
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
        winfixbuf = true,
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
        d = function()
            local node = node_at_cursor()
            if node and node.runnable then
                loomtest.debug(node.id, node.type)
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
            local node = node_at_cursor()
            if node then
                _selected_id = node.id
                M.show_output()
            end
        end,
        ["<C-r>"] = function() loomtest.refresh() end,
        p = function()
            config.show_passed = not config.show_passed
            M.refresh()
        end,
        -- Disable keymaps that would navigate away from the explorer
        ["-"] = function() end,
        ["<C-o>"] = function() end,
        ["<C-i>"] = function() end,
    }
    win_config.on_close = function()
        _win = nil
        _bufnr = nil
    end

    _win = Snacks.win(win_config)

    -- Lock cursor to actionable lines, but allow gg/G to work
    -- by snapping after a short defer
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = _bufnr,
        callback = function()
            vim.schedule(snap_cursor)
        end,
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
--- If opening, optionally reveal the test at cursor.
function M.toggle()
    if M.is_open() then
        M.close()
    else
        -- Find test at cursor in the source buffer before opening
        local test_id = M._find_current_test()
        M.open()
        if test_id then
            M.reveal(test_id)
        end
    end
end

--- Open the explorer and reveal a specific test.
--- @param test_id? string test to reveal (finds from cursor if nil)
function M.goto_test(test_id)
    if not test_id then
        test_id = M._find_current_test()
    end
    if not M.is_open() then
        M.open()
    else
        -- Focus the explorer window
        local win = _win and type(_win) == "table" and _win.win or nil
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
        end
    end
    if test_id then
        M.reveal(test_id)
    end
end

--- Reveal a test in the explorer by scrolling to its line.
--- Unfolds parents as needed.
--- @param test_id string
function M.reveal(test_id)
    if not M.is_open() then return end

    -- test_id format is "test:Suite.TestName"; suite fold IDs look like
    -- "target:Runner::SuiteName".
    local suite_name = test_id:match("^test:([^%.]+)%.")
    if suite_name then
        for fold_id in pairs(_folds) do
            if fold_id:match("::" .. vim.pesc(suite_name) .. "$") then
                _folds[fold_id] = nil
            end
        end
        for fold_id in pairs(_folds) do
            if fold_id:match("^target:") then
                _folds[fold_id] = nil
            end
        end
    end

    M.refresh()

    local target_line = nil
    for line, node in pairs(_line_data) do
        if node and node.id == test_id then
            target_line = line
            break
        end
    end

    if target_line then
        local win = _win and type(_win) == "table" and _win.win or nil
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
        end
    end
end

--- Find the test ID at the current cursor position in the source buffer.
--- @return string|nil test_id
function M._find_current_test()
    local bufnr = vim.api.nvim_get_current_buf()
    local buf_path = vim.api.nvim_buf_get_name(bufnr)
    if buf_path == "" then return nil end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local cursor_line = cursor[1]
    local norm_path = buf_path:gsub("\\", "/"):lower()

    local loomtest = require("loomtest")
    local best_id, best_line = nil, 0
    for _, node in ipairs(loomtest.nodes()) do
        if node.file and node.file:gsub("\\", "/"):lower() == norm_path
            and node.line and node.line <= cursor_line
            and node.line > best_line
            and node.type == "test" then
            best_id = node.id
            best_line = node.line
        end
    end
    return best_id
end

--- Show test output in a floating window.
function M.show_output()
    local loomtest = require("loomtest")

    if not _selected_id then
        vim.notify("loomtest: no test selected", vim.log.levels.INFO)
        return
    end

    local node = loomtest.get_node(_selected_id)

    -- For suite/target nodes, find a failed child
    if not node or (not node._output and not node.message and node.type ~= "test") then
        for _, n in ipairs(loomtest.nodes()) do
            if n.type == "test" and n.status == "failed"
                and (n._output or n.message)
                and n.id:find(_selected_id, 1, true) then
                node = n; break
            end
        end
    end

    if not node then
        vim.notify("loomtest: no output for this test", vim.log.levels.INFO)
        return
    end

    -- For tests with no output/message (e.g. passed tests)
    if not node._output and not node.message then
        local title = node.name .. " (" .. (node.status or "unknown") .. ")"
        M._show_output_float(title, "No output captured.", {})
        return
    end

    local output = node._output or node.message or ""
    if node.message and node._output and node.message ~= node._output then
        output = node.message .. "\n\n--- stdout/stderr ---\n" .. node._output
    end

    local title = node.name .. " (" .. (node.status or "unknown") .. ")"
    M._show_output_float(title, output, node._errors or {})
end

--- Display output in a floating window with highlights.
function M._show_output_float(title, output, errors)
    local lines = {}
    local hl_lines = {}  -- { line_num (0-based), hl_group }

    if #errors > 0 then
        lines[#lines + 1] = "Errors:"
        hl_lines[#hl_lines + 1] = { #lines - 1, "DiagnosticError" }
        lines[#lines + 1] = ""
        for _, err in ipairs(errors) do
            local loc = ""
            if err.file and err.line then
                loc = vim.fn.fnamemodify(err.file, ":t") .. ":" .. err.line .. "  "
            end
            local msg = (err.message or ""):gsub("\r", "")
            local first = true
            for msg_line in (msg .. "\n"):gmatch("([^\n]*)\n") do
                if first then
                    lines[#lines + 1] = "  " .. loc .. msg_line
                    first = false
                else
                    lines[#lines + 1] = "    " .. msg_line
                end
                hl_lines[#hl_lines + 1] = { #lines - 1, "DiagnosticWarn" }
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Output:"
        hl_lines[#hl_lines + 1] = { #lines - 1, "Title" }
        lines[#lines + 1] = ""
    end

    -- Output lines (strip \r from Windows line endings)
    output = output:gsub("\r", "")
    for _, l in ipairs(vim.split(output, "\n")) do
        lines[#lines + 1] = l
        if l:match("^%s*Expected") or l:match("^%s*Actual")
            or l:match("^%s*Value of") or l:match("ASSERT_")
            or l:match("EXPECT_") then
            hl_lines[#hl_lines + 1] = { #lines - 1, "DiagnosticWarn" }
        elseif l:match("%.cpp:%d+") or l:match("%.h:%d+") then
            hl_lines[#hl_lines + 1] = { #lines - 1, "DiagnosticInfo" }
        end
    end

    -- Build a lookup of line_num → { file, line } for jump-to-error
    local jump_targets = {}  -- 1-based line → { file, line }

    local error_line_start = 0
    if #errors > 0 then
        error_line_start = 3  -- after "Errors:" and blank line
        for i, err in ipairs(errors) do
            if err.file and err.line then
                jump_targets[error_line_start + (i - 1)] = {
                    file = err.file, line = err.line,
                }
            end
        end
    end

    for i, l in ipairs(lines) do
        if not jump_targets[i] then
            local file, lnum = l:match("([%w_/\\%.%-:]+%.[ch]pp?):(%d+)")
            if file and lnum then
                jump_targets[i] = { file = file, line = tonumber(lnum) }
            end
        end
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local ns = vim.api.nvim_create_namespace("loomtest_output")
    for _, hl in ipairs(hl_lines) do
        pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl[2], hl[1], 0, -1)
    end

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
        keys = {
            q = "close",
            ["<CR>"] = function(self)
                local cursor = vim.api.nvim_win_get_cursor(self.win)
                local target = jump_targets[cursor[1]]
                if not target then return end
                self:close()
                local target_win = nil
                for _, w in ipairs(vim.api.nvim_list_wins()) do
                    local wbuf = vim.api.nvim_win_get_buf(w)
                    if vim.bo[wbuf].buftype == "" then
                        target_win = w
                        break
                    end
                end
                if target_win then
                    vim.api.nvim_set_current_win(target_win)
                end
                vim.cmd("edit " .. vim.fn.fnameescape(target.file))
                pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
            end,
        },
        wo = { number = true, relativenumber = false, wrap = true },
    })
end

return M
