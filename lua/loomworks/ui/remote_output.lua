--- loomworks/ui/remote_output.lua — a daemon task's kept output in a
--- buffer: the Tasks section's `Show output` and a Profiles row's task
--- output in `daemon` mode (step 5o C2d-2).

local M = {}

--- Open a remote task's kept output in a read-only scratch buffer that
--- follows the stream while the task runs (spec/ui.md §1.9).
--- @param task loomworks.RemoteTask
function M.show(task)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    pcall(vim.api.nvim_buf_set_name, buf, "loomworks://daemon-task/" .. task.id .. "/" .. task.name)
    local pending = ""
    local function append_lines(lines)
        if #lines == 0 or not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        local n = vim.api.nvim_buf_line_count(buf)
        local first_empty = n == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
        vim.api.nvim_buf_set_lines(buf, first_empty and 0 or n, -1, false, lines)
        vim.bo[buf].modifiable = false
    end
    -- Complete lines go in; a trailing partial line waits for the rest.
    local function put(text)
        text = (pending .. (text or "")):gsub("\r\n", "\n")
        local lines = vim.split(text, "\n", { plain = true })
        pending = table.remove(lines)
        append_lines(lines)
    end
    local function flush()
        if pending ~= "" then append_lines({ pending }) end
        pending = ""
    end
    put(task:output())
    if task.finished then
        flush()
    else
        local unfollow
        unfollow = task:follow(function(_, text)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(buf) then
                    if unfollow then unfollow() end
                    return
                end
                if text == nil then
                    flush()
                    append_lines({ "[" .. task:outcome() .. "]" })
                    if unfollow then unfollow() end
                else
                    put(text)
                end
            end)
        end)
    end
    vim.bo[buf].modifiable = false
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
end

return M
