--- loomworks/health.lua — `:checkhealth loomworks`: the runtime mode and the
--- `lw` host binary the editor would launch the workspace daemon from, with
--- every source it tried and why each was not chosen (spec §19.16 "Host
--- binary"), the state of a download of the plugin-managed lw and the last
--- `binary.channel` check (step 5h.5). Read-only:
--- it launches and downloads nothing.

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
    elseif sel.download then
        -- The plugin-managed lw is wanted but not installed (step 5h.3): the
        -- observer downloads it in daemon mode; checkhealth never does.
        local state = require("loomworks.provision.fetch").describe(sel.download.sha256)
        if state and state:match("^could not") then
            h.warn(state, { "Check the network or binary.release_url / LOOMWORKS_RELEASE_URL, then "
                .. ":LoomworksDaemon connect; or install lw on PATH" })
        elseif state then
            h.info(state)
        elseif daemon then
            h.info("would download " .. binsel.describe(sel) .. ", then launch the workspace daemon from it")
        else
            h.info("no lw host binary (only used in daemon mode): " .. binsel.none_note(sel))
        end
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
        -- The cached pre-launch probe verdict (step 5h.5); checkhealth never probes.
        if c.probe and c.verdict == "chosen" then
            what = what .. " [probe: " .. require("loomworks.provision.probe").describe(c.probe) .. "]"
        end
        h.info(what)
    end
    if sel.warning then h.warn(sel.warning) end
    -- binary.channel (step 5h.5): the last check, from channel.json; never queries.
    local chan = require("loomworks.provision.channel").describe(lw._binary_config)
    for _, l in ipairs(chan or {}) do h.info(l) end
    if sel.channel_note then h.info(sel.channel_note) end
end

return M
