--- loomworks/ui/description_editor.lua — git-commit-style description editor
--- (spec/ui.md §1.16).
---
--- A floating scratch buffer (`buftype=acwrite`, filetype
--- `loomworks_description`) pre-filled with the item's description and `#`
--- help lines. `:w` (BufWriteCmd) drops the `#` lines, normalises the text and
--- applies it through the item's `set_description`; an empty result removes
--- the description. A refused text is reported inline and the buffer stays
--- modified. Closing without saving (`:q!`) discards the edit.

local M = {}

local ns = vim.api.nvim_create_namespace("loomworks_description_editor")

--- Kind label for an item ("profile", "configuration set", "project",
--- "configuration") and its display name.
--- @param item table
--- @return string kind, string name
function M.describe_item(item)
    -- A handle for an item that is not a domain object (a launch
    -- configuration, spec §8.7) names its own kind and label.
    if item._kind then return item._kind, item._label or "?" end
    local mt = getmetatable(item)
    if mt == require("loomworks.profile") then return "profile", tostring(item.key) end
    if mt == require("loomworks.configuration_set") then return "configuration set", item.name end
    if mt == require("loomworks.project") then return "project", item.key end
    if mt == require("loomworks.configuration") then
        return "configuration", (item._project and (item._project.key .. "/") or "") .. item.name
    end
    return "item", tostring(item.key or item.name)
end

--- Whether an item's description can be edited here. A generated
--- configuration's description comes from the project files (core §1.10).
--- @param item table
--- @return boolean ok, string|nil reason
function M.editable(item)
    local Configuration = require("loomworks.configuration")
    if getmetatable(item) == Configuration then
        if item:is_auto_gen() or not item.is_user or item._source_missing then
            return false, "configuration '" .. item.name .. "' is generated from the project files, "
                .. "which also supply its description; declare a configuration that inherits "
                .. "it to give it your own"
        end
    end
    return true, nil
end

--- The buffer's initial lines: the description, a blank line, then the `#`
--- help lines.
--- @param kind string
--- @param name string
--- @param desc string|nil
--- @return string[]
function M.initial_lines(kind, name, desc)
    local lines = {}
    if desc then
        for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do lines[#lines + 1] = l end
    else
        lines[1] = ""
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "# Describe " .. kind .. " '" .. name .. "'."
    lines[#lines + 1] = "# The first line is the summary shown in lists; add a blank line, then details."
    lines[#lines + 1] = "# Lines starting with '#' are ignored. Save an empty description to remove it."
    lines[#lines + 1] = "# :w saves · :q! discards"
    return lines
end

--- Apply the buffer's content to the item (the BufWriteCmd body). Returns
--- true when saved (or unchanged), false with the error when refused.
--- @param buf integer
--- @param item table
--- @param on_saved? fun(item: table) called after a successful save
--- @return boolean ok, string|nil err
function M.apply(buf, item, on_saved)
    local d = require("loomworks.description")
    local text = d.strip_comments(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    local changed, err = item:set_description(text)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if changed == nil then
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
            virt_lines = { { { "  " .. tostring(err), "ErrorMsg" } } },
            virt_lines_above = false,
        })
        vim.notify("loomworks: " .. tostring(err), vim.log.levels.ERROR)
        return false, err
    end
    vim.bo[buf].modified = false
    if on_saved then on_saved(item) end
    if changed then
        local kind, name = M.describe_item(item)
        vim.notify("loomworks: " .. kind .. " '" .. name .. "' "
            .. (item.description and "described" or "description removed"), vim.log.levels.INFO)
    end
    return true, nil
end

--- Open the editor for `item`. For a generated configuration, notifies and
--- returns nil (nothing opens).
--- @param item table Project|Configuration|ConfigurationSet|Profile
--- @param opts? { on_saved?: fun(item: table) }
--- @return integer|nil buf, integer|nil win
function M.open(item, opts)
    opts = opts or {}
    local ok, reason = M.editable(item)
    if not ok then
        vim.notify("loomworks: " .. reason, vim.log.levels.INFO)
        return nil, nil
    end
    local kind, name = M.describe_item(item)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "loomworks://description/" .. kind:gsub(" ", "-") .. "/" .. name
        .. "#" .. buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.initial_lines(kind, name, item.description))
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = "loomworks_description"
    vim.bo[buf].textwidth = 0

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function() M.apply(buf, item, opts.on_saved) end,
    })

    local width = math.min(80, math.max(40, vim.o.columns - 10))
    local height = math.min(20, math.max(8, vim.o.lines - 10))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        border = "rounded",
        title = " Description — " .. kind .. " " .. require("loomworks.description").inert_line(name) .. " ",
        title_pos = "center",
        zindex = 70,
    })
    vim.wo[win].wrap = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"

    -- Summary line highlighted; past 72 columns marked (advisory); # lines dim.
    vim.api.nvim_buf_call(buf, function()
        vim.cmd([[
            syntax clear
            syntax match LoomworksDescriptionOverflow /\%1l\%>72v.*/
            syntax match LoomworksDescriptionSummary /\%1l.*/ contains=LoomworksDescriptionOverflow
            syntax match LoomworksDescriptionComment /^#.*/
            highlight default link LoomworksDescriptionSummary Title
            highlight default link LoomworksDescriptionOverflow WarningMsg
            highlight default link LoomworksDescriptionComment Comment
        ]])
    end)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    return buf, win
end

return M
