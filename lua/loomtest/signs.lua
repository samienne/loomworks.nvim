--- loomtest/signs.lua — Gutter sign management.
---
--- Places test status signs in source buffers based on TestNode
--- file/line data. Aggregates status for multiple tests on the same line.

local M = {}

local SIGN_GROUP = "loomtest"
local NS = vim.api.nvim_create_namespace("loomtest_signs")

local SIGN_DEFS = {
    passed  = { text = "✔", texthl = "DiagnosticOk" },
    failed  = { text = "✗", texthl = "DiagnosticError" },
    skipped = { text = "⊘", texthl = "DiagnosticWarn" },
    errored = { text = "!", texthl = "DiagnosticError" },
    unknown = { text = "○", texthl = "Comment" },
    running = { text = "↻", texthl = "DiagnosticInfo" },
    pending = { text = "↻", texthl = "DiagnosticInfo" },
}

local _signs_defined = false

local function define_signs()
    if _signs_defined then return end
    _signs_defined = true
    for name, def in pairs(SIGN_DEFS) do
        vim.fn.sign_define("loomtest_" .. name, {
            text = def.text,
            texthl = def.texthl,
        })
    end
end

--- Aggregate status for multiple tests on the same line.
--- Priority: failed/errored > running > skipped > passed > unknown.
--- @param statuses string[]
--- @return string
local function aggregate_status(statuses)
    local has = {}
    for _, s in ipairs(statuses) do
        has[s or "unknown"] = true
    end
    if has.failed or has.errored then return "failed" end
    if has.running or has.pending then return "running" end
    if has.skipped then return "skipped" end
    if has.passed then return "passed" end
    return "unknown"
end

--- Update signs for a specific buffer.
--- @param bufnr number
function M.update_buf(bufnr)
    define_signs()

    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local buf_path = vim.api.nvim_buf_get_name(bufnr)
    if buf_path == "" then return end

    local norm_path = buf_path:gsub("\\", "/"):lower()

    -- Clear existing signs
    vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })

    -- Collect tests per line
    local loomtest = require("loomtest")
    local by_line = {}
    for _, node in ipairs(loomtest.nodes()) do
        if node.file and node.file:gsub("\\", "/"):lower() == norm_path and node.line then
            by_line[node.line] = by_line[node.line] or {}
            by_line[node.line][#by_line[node.line] + 1] = node.status
        end
    end

    -- Place signs
    for line, statuses in pairs(by_line) do
        local status = aggregate_status(statuses)
        local sign_name = "loomtest_" .. status
        pcall(vim.fn.sign_place, 0, SIGN_GROUP, sign_name, bufnr, { lnum = line, priority = 15 })
    end
end

--- Update signs for all open buffers.
function M.update_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            M.update_buf(bufnr)
        end
    end
end

--- Set up autocmds for automatic sign updates.
function M.setup()
    local group = vim.api.nvim_create_augroup("loomtest_signs", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(ev)
            M.update_buf(ev.buf)
        end,
    })
end

return M
