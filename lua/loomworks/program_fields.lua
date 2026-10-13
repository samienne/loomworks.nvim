--- loomworks/program_fields.lua — Program-bearing configuration fields
--- (spec §17.6).
---
--- A program-bearing field names a program to run, adds arguments to one, sets
--- a spawned environment or working directory, or places a deploy outside the
--- workspace. Such fields are honored only from the signed working copy
--- (`.nvim/loomworks.user.json`); in the shared snapshot (`loomworks.json`)
--- they are ignored. This module:
---
---   * `strip(config, modules)` removes them from a parsed shared config (the
---     internal `config.parse` shape) BEFORE it is merged, returning the list of
---     ignored entries — so they never reach the in-memory model and can never
---     be copied (cascade / auto-sync / revert) into the signed working copy;
---   * `regraft(raw, ignored)` writes them back into a serialized
---     loomworks.json (raw shape) on publish, so publishing never drops a
---     teammate's committed value;
---   * `diagnostics(ignored, merged)` reports each ignored value that nothing
---     in the working copy supplies;
---   * `review(user_data, modules)` summarizes a working copy for the trust
---     prompt, program-bearing fields first.
---
--- Core defines the generic fields (configuration `env` and compiler-family
--- `overrides.<family>.env`, launch configurations naming a program /
--- arguments / environment / working directory, deploy destinations not
--- statically inside the workspace, a `device` block's `env` / `working_dir`); modules add top-level `type_config` keys
--- through their optional `trust_fields = { type_config = {...}, review = {...} }`
--- declaration (spec §8.4). No module names appear here.

local M = {}

--- Launch-configuration keys that make a launch program-bearing. A launch that
--- sets any of them is ignored as a whole (spec §17.6) so a partially stripped
--- launch never runs something other than what was written.
M.LAUNCH_KEYS = { "command", "args", "env", "working_dir" }

--- Program-bearing fields of a `device` block (spec §18.9): the device-side
--- environment and working directory. `stage` / `archive` are statically
--- confined to the build directory and honored from shared config.
M.DEVICE_KEYS = { "env", "working_dir" }

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function short(v, max)
    max = max or 60
    local s
    if type(v) == "string" then
        s = v
    elseif type(v) == "table" then
        if vim.tbl_isarray and vim.tbl_isarray(v) and #v > 0 then
            local parts = {}
            for i, x in ipairs(v) do parts[i] = tostring(x) end
            s = "[" .. table.concat(parts, " ") .. "]"
        else
            local ks = sorted_keys(v)
            local parts = {}
            for _, k in ipairs(ks) do
                local x = v[k]
                parts[#parts + 1] = tostring(k) .. (type(x) == "string" and ("=" .. x) or "")
            end
            s = "{" .. table.concat(parts, ", ") .. "}"
        end
    else
        s = tostring(v)
    end
    s = s:gsub("[%c]", " ")
    if #s > max then s = s:sub(1, max - 1) .. "…" end
    return s
end
M._short = short

--- Whether a deploy destination template is statically inside the workspace:
--- a relative path, optionally prefixed by `${workspace_root}/`, with no other
--- variable reference and no `.`/`..` segment (spec §17.6).
--- @param dest any
--- @return boolean
function M.dest_is_local(dest)
    if type(dest) ~= "string" or dest == "" then return false end
    local rest = dest:gsub("^%${workspace_root}[/\\]", "")
    if rest:find("${", 1, true) or rest:find("%$") then return false end
    if rest:match("^[/\\]") or rest:match("^%a:") or rest:match("^~") then return false end
    for seg in rest:gmatch("[^/\\]+") do
        if seg == ".." or seg == "." then return false end
    end
    return rest ~= ""
end

--- Program-bearing type_config keys a module declares.
--- @param modules table|nil module registry (`get(type)`)
--- @param mod_type string
--- @return string[] strip, string[] review
local function module_fields(modules, mod_type)
    if not modules or type(modules.get) ~= "function" then return {}, {} end
    local ok, mod = pcall(modules.get, mod_type)
    if not ok or type(mod) ~= "table" or type(mod.trust_fields) ~= "table" then return {}, {} end
    local tf = mod.trust_fields
    return type(tf.type_config) == "table" and tf.type_config or {},
        type(tf.review) == "table" and tf.review or {}
end

--- Remove program-bearing fields from a parsed shared config, in place.
--- @param config table parsed loomworks.json (`config.parse` shape)
--- @param modules table|nil module registry
--- @return table[] ignored entries `{ project, kind, path, raw_path, value, label, detail }`
function M.strip(config, modules)
    local ignored = {}
    if type(config) ~= "table" then return ignored end
    -- SDK declarations carry requirements only; a path in shared data is never
    -- honored (spec §17.6).
    if type(config.sdks) == "table" then
        for _, key in ipairs(sorted_keys(config.sdks)) do
            local decl = config.sdks[key]
            if type(decl) == "table" then
                for _, f in ipairs({ "_user", "path" }) do
                    if decl[f] ~= nil then
                        ignored[#ignored + 1] = {
                            kind = "sdk", value = decl[f],
                            path = { "sdks", key, f }, raw_path = { "sdks", key, f },
                            anchor = 2,
                            label = "sdks." .. key .. "." .. f,
                            detail = short(decl[f]),
                        }
                        decl[f] = nil
                    end
                end
            end
        end
    end
    for _, pkey in ipairs(sorted_keys(config.projects)) do
        local proj = config.projects[pkey]
        if type(proj) == "table" then
            local mtype = proj.type or "?"
            local tc = proj.type_config
            local function add(e)
                e.project = pkey
                ignored[#ignored + 1] = e
            end
            -- (1) Module-declared type_config keys.
            if type(tc) == "table" then
                local strip_keys = module_fields(modules, mtype)
                for _, k in ipairs(strip_keys) do
                    if tc[k] ~= nil then
                        add({
                            kind = "type_config", value = tc[k],
                            path = { "projects", pkey, "type_config", k },
                            raw_path = { "projects", pkey, mtype, k },
                            anchor = 3,
                            label = "projects." .. pkey .. "." .. mtype .. "." .. k,
                            detail = short(tc[k]),
                        })
                        tc[k] = nil
                    end
                end
                -- (2) Configuration environments.
                if type(tc.configurations) == "table" then
                    for _, cname in ipairs(sorted_keys(tc.configurations)) do
                        local c = tc.configurations[cname]
                        if type(c) == "table" then
                            if c.env ~= nil then
                                add({
                                    kind = "env", value = c.env,
                                    path = { "projects", pkey, "type_config", "configurations", cname, "env" },
                                    raw_path = { "projects", pkey, mtype, "configurations", cname, "env" },
                                    anchor = 5,
                                    label = "projects." .. pkey .. "." .. mtype .. ".configurations." .. cname .. ".env",
                                    detail = short(c.env),
                                })
                                c.env = nil
                            end
                            if type(c.overrides) == "table" then
                                for _, fam in ipairs(sorted_keys(c.overrides)) do
                                    local block = c.overrides[fam]
                                    if type(block) == "table" and block.env ~= nil then
                                        add({
                                            kind = "env", value = block.env,
                                            path = { "projects", pkey, "type_config", "configurations", cname, "overrides", fam, "env" },
                                            raw_path = { "projects", pkey, mtype, "configurations", cname, "overrides", fam, "env" },
                                            anchor = 5,
                                            label = "projects." .. pkey .. "." .. mtype .. ".configurations." .. cname
                                                .. ".overrides." .. fam .. ".env",
                                            detail = short(block.env),
                                        })
                                        block.env = nil
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- (3) Launch configurations naming a program / args / env / cwd.
            if type(proj.launch) == "table" then
                for _, lname in ipairs(sorted_keys(proj.launch)) do
                    local l = proj.launch[lname]
                    if type(l) == "table" then
                        local hits = {}
                        for _, k in ipairs(M.LAUNCH_KEYS) do
                            if l[k] ~= nil then hits[#hits + 1] = k .. " = " .. short(l[k], 40) end
                        end
                        if #hits > 0 then
                            add({
                                kind = "launch", value = l,
                                path = { "projects", pkey, "launch", lname },
                                raw_path = { "projects", pkey, "launch", lname },
                                anchor = 2,
                                label = "projects." .. pkey .. ".launch." .. lname,
                                detail = table.concat(hits, ", "),
                            })
                            proj.launch[lname] = nil
                        else
                            -- (3b) A launch-level device block's program-bearing
                            -- fields (spec §18.9): env and working_dir.
                            if type(l.device) == "table" then
                                for _, f in ipairs(M.DEVICE_KEYS) do
                                    if l.device[f] ~= nil then
                                        add({
                                            kind = "device", value = l.device[f],
                                            path = { "projects", pkey, "launch", lname, "device", f },
                                            raw_path = { "projects", pkey, "launch", lname, "device", f },
                                            anchor = 4,
                                            label = "projects." .. pkey .. ".launch." .. lname .. ".device." .. f,
                                            detail = short(l.device[f]),
                                        })
                                        l.device[f] = nil
                                    end
                                end
                                if next(l.device) == nil then l.device = nil end
                            end
                        end
                        if proj.launch[lname] and type(l.deploy) == "table" then
                            for _, dest in ipairs(sorted_keys(l.deploy)) do
                                if not M.dest_is_local(dest) then
                                    add({
                                        kind = "deploy", value = l.deploy[dest],
                                        path = { "projects", pkey, "launch", lname, "deploy", dest },
                                        raw_path = { "projects", pkey, "launch", lname, "deploy", dest },
                                        anchor = 4,
                                        label = "projects." .. pkey .. ".launch." .. lname .. ".deploy",
                                        detail = "destination " .. dest,
                                    })
                                    l.deploy[dest] = nil
                                end
                            end
                        end
                    end
                end
                if next(proj.launch) == nil then proj.launch = nil end
            end
            -- (5) Project-level device block: env / working_dir are
            -- program-bearing; stage / archive patterns are not (spec §18.9).
            -- Parsed onto the project; it lives in the module section of the
            -- raw file (`projects.<p>.<type>.device`), where it is regrafted.
            if type(proj.device) == "table" then
                local mtype = proj.type or "?"
                for _, f in ipairs(M.DEVICE_KEYS) do
                    if proj.device[f] ~= nil then
                        add({
                            kind = "device", value = proj.device[f],
                            path = { "projects", pkey, "device", f },
                            raw_path = { "projects", pkey, mtype, "device", f },
                            anchor = 2,
                            label = "projects." .. pkey .. "." .. mtype .. ".device." .. f,
                            detail = short(proj.device[f]),
                        })
                        proj.device[f] = nil
                    end
                end
                if next(proj.device) == nil then proj.device = nil end
            end
            -- (4) Project-level deploy destinations.
            if type(proj.deploy) == "table" then
                for _, dest in ipairs(sorted_keys(proj.deploy)) do
                    if not M.dest_is_local(dest) then
                        add({
                            kind = "deploy", value = proj.deploy[dest],
                            path = { "projects", pkey, "deploy", dest },
                            raw_path = { "projects", pkey, "deploy", dest },
                            anchor = 2,
                            label = "projects." .. pkey .. ".deploy",
                            detail = "destination " .. dest,
                        })
                        proj.deploy[dest] = nil
                    end
                end
                if next(proj.deploy) == nil then proj.deploy = nil end
            end
        end
    end
    return ignored
end

local function get_path(t, path, upto)
    local cur = t
    for i = 1, (upto or #path) do
        if type(cur) ~= "table" then return nil end
        cur = cur[path[i]]
    end
    return cur
end

--- Write ignored values back into a serialized loomworks.json (raw shape), in
--- place: each entry whose anchor item (the project / configuration / launch
--- entry owning it) is present in `raw` and that `raw` does not already set is
--- restored, creating intermediate tables below the anchor. Entries whose
--- anchor is absent (the item was removed or not published) are dropped.
--- @param raw table serialized loomworks.json content
--- @param ignored table[]|nil
--- @return table raw
function M.regraft(raw, ignored)
    for _, e in ipairs(ignored or {}) do
        local rp = e.raw_path
        if rp and get_path(raw, rp) == nil then
            local anchor = get_path(raw, rp, e.anchor)
            if type(anchor) == "table" then
                local cur = anchor
                for i = e.anchor + 1, #rp - 1 do
                    if type(cur[rp[i]]) ~= "table" then cur[rp[i]] = {} end
                    cur = cur[rp[i]]
                end
                cur[rp[#rp]] = vim.deepcopy(e.value)
            end
        end
    end
    return raw
end

--- For an ignored launch, its description's summary (spec §17.6), quoted and
--- rendered inert (§17.11), so the user can tell which launch it is. "" for
--- anything else or a launch without a description.
--- @param e table ignored entry
--- @return string
local function launch_summary(e)
    if e.kind ~= "launch" or type(e.value) ~= "table" then return "" end
    local d = require("loomworks.description")
    local sum = d.summary(d.normalize(e.value.description))
    if not sum then return "" end
    return " \"" .. d.fit(d.inert_line(sum), 60) .. "\""
end

--- The ignored shared values still in effect: those the working copy does
--- not supply in their place (spec §17.6).
--- @param ignored table[]|nil
--- @param merged table|nil merged config (internal shape) the model was built from
--- @return table[] ignored entries
function M.active(ignored, merged)
    local out = {}
    for _, e in ipairs(ignored or {}) do
        if get_path(merged, e.path) == nil then out[#out + 1] = e end
    end
    return out
end

--- Diagnostics for ignored shared values that the working copy does not supply.
--- @param ignored table[]|nil
--- @param merged table|nil merged config (internal shape) the model was built from
--- @return loomworks.Diagnostic[]
function M.diagnostics(ignored, merged)
    local out = {}
    for _, e in ipairs(M.active(ignored, merged)) do
        out[#out + 1] = {
            severity = "warn",
            source = e.project and ("Project/" .. e.project) or "Workspace",
            message = "loomworks.json sets " .. e.label .. " (" .. e.detail .. ")"
                .. launch_summary(e)
                .. " — ignored: program settings are used only from your local config (lw help trust)",
            target_fold_key = e.project and ("project:" .. e.project) or nil,
        }
    end
    return out
end

--- Summarize a working copy for the trust review: program-bearing fields
--- first (what loomworks may run on its strength), then a count of the rest.
--- `user_data` is the decoded user.json (raw project shape).
--- @param user_data table
--- @param modules table|nil module registry
--- @return string[] program lines, string[] other lines
function M.review(user_data, modules)
    local prog, other = {}, {}
    local device_other = {}  -- device stage / archive sets (what is copied to a device)
    if type(user_data) ~= "table" then return prog, other end
    local function p(s) prog[#prog + 1] = s end

    local projects = type(user_data.projects) == "table" and user_data.projects or {}
    for _, pkey in ipairs(sorted_keys(projects)) do
        local proj = projects[pkey]
        if type(proj) == "table" then
            -- Raw shape: the type key is the one table-valued key that is not a
            -- generic project key.
            local generic = { path = true, depends_on = true, launch = true,
                variables = true, deploy = true, device = true, type = true, type_config = true }
            local mtype, tc = proj.type, proj.type_config
            if not tc then
                for k, v in pairs(proj) do
                    if not generic[k] and type(v) == "table" then mtype, tc = k, v end
                end
            end
            mtype = mtype or "?"
            if type(tc) == "table" then
                local strip_keys, review_keys = module_fields(modules, mtype)
                for _, list in ipairs({ strip_keys, review_keys }) do
                    for _, k in ipairs(list) do
                        if tc[k] ~= nil then
                            p("projects." .. pkey .. "." .. mtype .. "." .. k .. " = " .. short(tc[k], 90))
                        end
                    end
                end
                if type(tc.configurations) == "table" then
                    for _, cname in ipairs(sorted_keys(tc.configurations)) do
                        local c = tc.configurations[cname]
                        if type(c) == "table" then
                            if type(c.env) == "table" and next(c.env) then
                                p("projects." .. pkey .. "." .. mtype .. ".configurations." .. cname
                                    .. ".env = " .. short(c.env, 90))
                            end
                            if type(c.overrides) == "table" then
                                for _, fam in ipairs(sorted_keys(c.overrides)) do
                                    local b = c.overrides[fam]
                                    if type(b) == "table" and type(b.env) == "table" and next(b.env) then
                                        p("projects." .. pkey .. "." .. mtype .. ".configurations." .. cname
                                            .. ".overrides." .. fam .. ".env = " .. short(b.env, 90))
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if type(proj.launch) == "table" then
                for _, lname in ipairs(sorted_keys(proj.launch)) do
                    local l = proj.launch[lname]
                    if type(l) == "table" then
                        local hits = {}
                        for _, k in ipairs(M.LAUNCH_KEYS) do
                            if l[k] ~= nil then hits[#hits + 1] = k .. " = " .. short(l[k], 50) end
                        end
                        if type(l.deploy) == "table" then
                            for _, dest in ipairs(sorted_keys(l.deploy)) do
                                hits[#hits + 1] = "deploy → " .. dest
                            end
                        end
                        if type(l.device) == "table" then
                            for _, f in ipairs(M.DEVICE_KEYS) do
                                if l.device[f] ~= nil then
                                    hits[#hits + 1] = "device." .. f .. " = " .. short(l.device[f], 50)
                                end
                            end
                            for _, f in ipairs({ "stage", "archive" }) do
                                if l.device[f] ~= nil then
                                    device_other[#device_other + 1] = "projects." .. pkey .. ".launch." .. lname
                                        .. ".device." .. f .. " = " .. short(l.device[f], 90)
                                end
                            end
                        end
                        if #hits > 0 then
                            p("projects." .. pkey .. ".launch." .. lname .. ": " .. table.concat(hits, ", "))
                        end
                    end
                end
            end
            if type(proj.deploy) == "table" then
                for _, dest in ipairs(sorted_keys(proj.deploy)) do
                    p("projects." .. pkey .. ".deploy → " .. dest)
                end
            end
            -- The device block (spec §18.9): in the module section, or at the
            -- former project-level location. env / working_dir are program
            -- settings; stage / archive (what is copied to a device) are listed
            -- with the other contents.
            local dev, dev_label = nil, nil
            if type(tc) == "table" and type(tc.device) == "table" then
                dev, dev_label = tc.device, "projects." .. pkey .. "." .. mtype .. ".device."
            elseif type(proj.device) == "table" then
                dev, dev_label = proj.device, "projects." .. pkey .. ".device."
            end
            if dev then
                for _, f in ipairs(M.DEVICE_KEYS) do
                    if dev[f] ~= nil then p(dev_label .. f .. " = " .. short(dev[f], 90)) end
                end
                for _, f in ipairs({ "stage", "archive" }) do
                    if dev[f] ~= nil then device_other[#device_other + 1] = dev_label .. f .. " = " .. short(dev[f], 90) end
                end
            end
        end
    end
    if type(user_data.sdks) == "table" then
        for _, key in ipairs(sorted_keys(user_data.sdks)) do
            local s = user_data.sdks[key]
            if type(s) == "table" and s.path then
                p("sdks." .. key .. ".path = " .. short(s.path, 90))
            end
        end
    end
    if type(user_data.lsp) == "table" then
        for _, server in ipairs(sorted_keys(user_data.lsp)) do
            local opts = user_data.lsp[server]
            if type(opts) == "table" and next(opts) then
                p("lsp." .. server .. " = " .. short(opts, 90))
            end
        end
    end
    if type(user_data.profile_variables) == "table" then
        for _, prof in ipairs(sorted_keys(user_data.profile_variables)) do
            local byproj = user_data.profile_variables[prof]
            if type(byproj) == "table" then
                for _, pk in ipairs(sorted_keys(byproj)) do
                    if type(byproj[pk]) == "table" and next(byproj[pk]) then
                        p("profile_variables." .. prof .. "." .. pk .. " = " .. short(byproj[pk], 90))
                    end
                end
            end
        end
    end
    if type(user_data.debug) == "table" and next(user_data.debug) then
        p("debug = " .. short(user_data.debug, 90))
    end

    local function count(t) local n = 0; for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end; return n end
    for _, l in ipairs(device_other) do other[#other + 1] = l end
    other[#other + 1] = string.format("%d project(s), %d configuration set(s), %d profile(s)",
        count(user_data.projects), count(user_data.configuration_sets), count(user_data.profiles))
    if type(user_data.active_profile) == "string" then
        other[#other + 1] = "active profile: " .. user_data.active_profile
    end
    return prog, other
end

return M
