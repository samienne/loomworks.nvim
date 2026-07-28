--- loomtest/inline.lua — Inline test result annotations.
---
--- Places virtual text extmarks in source buffers showing:
--- 1. Test-level pass/fail + duration at the TEST() macro line
--- 2. Assertion-level error messages at the failing assertion line

local M = {}

local NS = vim.api.nvim_create_namespace("loomtest_inline")
local DIAG_NS = vim.api.nvim_create_namespace("loomtest_diagnostics")

local STATUS_TEXT = {
    passed  = { text = "✔ passed", hl = "DiagnosticOk" },
    failed  = { text = "✗ failed", hl = "DiagnosticError" },
    skipped = { text = "⊘ skipped", hl = "DiagnosticWarn" },
    errored = { text = "! errored", hl = "DiagnosticError" },
    running = { text = "↻ running", hl = "DiagnosticInfo" },
    pending = { text = "◌ pending", hl = "DiagnosticHint" },
}

--- Update inline annotations for a specific buffer.
--- @param bufnr number
function M.update_buf(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    local loomtest = require("loomtest")
    local config = loomtest.config()
    local inline_config = config.inline or {}
    if inline_config.enabled == false then return end

    local show_test = inline_config.test_result ~= false
    local show_error = inline_config.error_detail ~= false

    local buf_path = vim.api.nvim_buf_get_name(bufnr)
    if buf_path == "" then return end
    local norm_path = buf_path:gsub("\\", "/"):lower()

    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    local line_count = vim.api.nvim_buf_line_count(bufnr)

    if show_test then
        for _, node in ipairs(loomtest.nodes()) do
            if node.file and node.file:gsub("\\", "/"):lower() == norm_path
                and node.line and node.status then
                local line = node.line - 1  -- 0-based
                if line >= 0 and line < line_count then
                    local st = STATUS_TEXT[node.status]
                    if st then
                        local virt = { { "  " .. st.text, st.hl } }
                        if node.duration then
                            local dur
                            if node.duration < 1000 then
                                dur = string.format("%dms", node.duration)
                            else
                                dur = string.format("%.1fs", node.duration / 1000)
                            end
                            virt[#virt + 1] = { " " .. dur, "Comment" }
                        end
                        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line, 0, {
                            virt_text = virt,
                            virt_text_pos = "eol",
                            hl_mode = "combine",
                        })
                    end
                end
            end
        end
    end

    -- Publish assertion-level errors as vim diagnostics.
    -- This integrates with <leader>d, [d/]d, and diagnostic UI.
    local diagnostics = {}
    if show_error then
        for _, node in ipairs(loomtest.nodes()) do
            if node._errors and node.file
                and node.file:gsub("\\", "/"):lower() == norm_path then
                for _, err in ipairs(node._errors) do
                    if err.file and err.line then
                        local err_norm = err.file:gsub("\\", "/"):lower()
                        if err_norm == norm_path then
                            local msg = err.message or "test assertion failed"
                            diagnostics[#diagnostics + 1] = {
                                lnum = err.line - 1,
                                col = 0,
                                end_col = 0,  -- no underline
                                message = msg,
                                severity = vim.diagnostic.severity.ERROR,
                                source = "loomtest",
                            }
                        end
                    end
                end
            end
            -- Also add a diagnostic for failed tests at the TEST() line
            if node.status == "failed" and node.message
                and node.file and node.file:gsub("\\", "/"):lower() == norm_path
                and node.line then
                local line = node.line - 1
                local has_error_at_line = false
                for _, d in ipairs(diagnostics) do
                    if d.lnum == line then has_error_at_line = true; break end
                end
                if not has_error_at_line then
                    diagnostics[#diagnostics + 1] = {
                        lnum = line,
                        col = 0,
                        message = node.message:gsub("\n.*", ""):sub(1, 100),
                        severity = vim.diagnostic.severity.ERROR,
                        source = "loomtest",
                    }
                end
            end
        end
    end
    vim.diagnostic.set(DIAG_NS, bufnr, diagnostics)
end

--- Update inline annotations for all open buffers.
function M.update_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            M.update_buf(bufnr)
        end
    end
end

--- Clear all inline annotations and diagnostics.
function M.clear_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
        end
    end
    vim.diagnostic.reset(DIAG_NS)
end

--- Set up autocmds for automatic inline updates.
function M.setup()
    local group = vim.api.nvim_create_augroup("loomtest_inline", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(ev)
            M.update_buf(ev.buf)
        end,
    })

    -- Configure diagnostic display for test results:
    -- - No underline (too noisy)
    -- - Signs enabled (for assertion lines — our gutter signs handle TEST() lines)
    -- - Virtual text enabled (shows error message inline, consistent with LSP style)
    vim.diagnostic.config({
        underline = false,
        signs = {
            priority = 8,  -- lower than our loomtest signs (default 10)
        },
        virtual_text = {
            prefix = "✗",
            source = false,
        },
    }, DIAG_NS)
end

return M
