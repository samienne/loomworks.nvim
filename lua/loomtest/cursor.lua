--- loomtest/cursor.lua — Find test at cursor position.
---
--- Utility for mapping a cursor position in a source buffer to a test ID.
--- Delegates to adapters via get_cursor_test().

local M = {}

--- Find the test at the given buffer position.
--- Queries all registered adapters.
--- @param bufnr? number defaults to current buffer
--- @param line? number 1-based, defaults to cursor line
--- @return string|nil test_id, loomtest.TestAdapter|nil adapter
function M.find(bufnr, line)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not line then
        local cursor = vim.api.nvim_win_get_cursor(0)
        line = cursor[1]
    end

    local loomtest = require("loomtest")
    for _, adapter in ipairs(loomtest.adapters()) do
        local test_id = adapter.get_cursor_test(bufnr, line)
        if test_id then
            return test_id, adapter
        end
    end
    return nil, nil
end

return M
