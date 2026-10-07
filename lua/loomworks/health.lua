--- loomworks/health.lua — `:checkhealth loomworks`: the runtime mode and the
--- `lw` host binary the editor would launch the workspace daemon from, with
--- every source it tried and why each was not chosen (spec §19.16 "Host
--- binary"). Read-only: it launches and downloads nothing.

local M = {}

--- Render the report. `h` replaces vim.health and `lw` the plugin facade
--- (tests inject).
--- @param h? table
--- @param lw? table
function M.check(h, lw)
    h = h or vim.health
    lw = lw or require("loomworks")
    local binsel = require("loomworks.provision.select")

    h.start("loomworks: runtime")
    local mode, source = lw.runtime_mode()
    h.info(string.format("runtime mode: %s (%s)", tostring(mode), tostring(source)))
    local line = lw.daemon_runtime_line()
    if line then h.info("status: " .. line) end

    h.start("loomworks: lw host binary")
    local sel = lw.host_binary_selection()
    local daemon = mode == "daemon"
    if sel.path then
        h.ok("would launch the workspace daemon from " .. binsel.describe(sel))
    elseif daemon then
        h.warn(binsel.none_note(sel), {
            "Install lw on PATH, or set LOOMWORKS_LW or setup({ binary = { path = ... } })",
        })
    else
        h.info("no lw host binary (only used in daemon mode): " .. binsel.none_note(sel))
    end
    for _, c in ipairs(sel.candidates or {}) do
        local what = c.label .. ": " .. c.verdict
        if c.path then what = what .. " — " .. c.path end
        if c.reason then what = what .. " (" .. c.reason .. ")" end
        h.info(what)
    end
    if sel.warning then h.warn(sel.warning) end
end

return M
