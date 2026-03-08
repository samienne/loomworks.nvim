local M = {}

M._version = "0.0.1-dev"

function M.hello()
    vim.notify("loomworks.nvim " .. M._version .. " is loaded!", vim.log.levels.INFO, { title = "loomworks" })
end

return M
