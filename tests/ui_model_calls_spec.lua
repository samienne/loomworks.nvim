-- The status page's one route to model writes (loomworks.ui.model_calls,
-- step 5o part C0): every method it serves is a catalogue method named with
-- its interface (spec §19.20), and no other ui/ file reaches a model write
-- itself (guard ratchet).

local model = require("loomworks.ui.model_calls")

local root = vim.fn.getcwd()

--- The methods `iface` (e.g. "Profiles") declares at version `v`.
local function schema_methods(iface, v)
    local fh = io.open(("%s/spec/protocol/interfaces/loomworks/%s.%d.json"):format(root, iface, v), "rb")
    if not fh then return nil end
    local doc = vim.json.decode(fh:read("*a"))
    fh:close()
    return doc.methods or {}
end

describe("ui.model_calls", function()
    it("serves only catalogue methods, each named <Interface>/<version>.<method>", function()
        local bad = {}
        local names = model.methods()
        assert.is_true(#names > 0)
        for _, name in ipairs(names) do
            local iface, v, method = name:match("^([%w_]+)/(%d+)%.([%w_]+)$")
            local methods = iface and schema_methods(iface, tonumber(v))
            if not methods then
                bad[#bad + 1] = name .. ": no interface loomworks." .. tostring(iface) .. "/" .. tostring(v)
            elseif not methods[method] then
                bad[#bad + 1] = name .. ": the interface has no method " .. method
            end
        end
        assert.same({}, bad)
    end)

    it("refuses an unknown method loudly", function()
        assert.has_error(function() model.call(nil, "Profiles/1.nope", {}) end)
        assert.has_error(function() model.call(nil, "set_active", {}) end)
    end)

    -- C0: each method's body is the in-process write the editor ran before.
    -- The view-model and the loomworks API are stubbed to record what each
    -- method passes and to check how its answer becomes the outcome.
    describe("in-process bodies", function()
        local saved, calls
        local function recorder(ret)
            return setmetatable({}, { __index = function(_, name)
                return function(...)
                    calls[#calls + 1] = { name, ... }
                    if type(ret[name]) == "function" then return ret[name](...) end
                    return true
                end
            end })
        end
        local WS, P, CS, PR, CFG, L, SDK, U = {}, {}, {}, {}, {}, {}, {}, {}
        before_each(function()
            calls = {}
            saved = { package.loaded["loomworks.workspace_view"], package.loaded["loomworks"] }
            package.loaded["loomworks.workspace_view"] = recorder({
                set_description = function() return false end,
                execute_create_profile = function() return P end,
                execute_create_config_set = function() return nil, "taken" end,
                execute_create_config_set_from_candidate = function() return CS end,
                execute_add_project = function() return true, nil, PR end,
                execute_save_launch_config = function() return true, nil, L end,
                add_sdk = function() return SDK end,
                remove_sdk = function() return false, "in use" end,
                execute_delete_stray_dir = function(_, _, done) done(false, nil) end,
                execute_orphan_cleanup = function(_, _, _, done) done(true) end,
                execute_remove_project = function(_, _, _, done) done(false, "locked") end,
            })
            package.loaded["loomworks"] = recorder({
                trust_user_prefs = function() return "trusted" end,
                execute_deletion = function(_, _, done) done() end,
            })
        end)
        after_each(function()
            package.loaded["loomworks.workspace_view"], package.loaded["loomworks"] = saved[1], saved[2]
        end)
        local function run(ws, method, params)
            local got
            model.call(ws, method, params, function(r) got = r end)
            return got
        end

        it("passes each method's params to the write the editor ran before", function()
            local m = { a = 1 }
            local r = {}
            r[#r + 1] = run(WS, "Workspace/1.publish", {})
            r[#r + 1] = run(nil, "Workspace/1.set_intent", { item = P, intent = "shared" })
            r[#r + 1] = run(nil, "Workspace/1.set_description", { item = L, text = "t" })
            r[#r + 1] = run(nil, "Profiles/1.create", { config_set = CS, tool = m, activate = true })
            r[#r + 1] = run(nil, "Profiles/1.add_tool", { profile = P, tool = "gcc" })
            r[#r + 1] = run(WS, "ConfigSets/1.add", { name = "Dev", mappings = m })
            r[#r + 1] = run(WS, "ConfigSets/1.add", { candidate = "tok" })
            r[#r + 1] = run(nil, "ConfigSets/1.update", { config_set = CS, name = "D2", mappings = m })
            r[#r + 1] = run(WS, "Projects/1.add", { key = "app", type = "cmake", path = "app", mappings = m, tool = m })
            r[#r + 1] = run(nil, "Projects/1.configuration_save",
                { project = PR, configuration = CFG, name = "Debug", fields = m })
            r[#r + 1] = run(nil, "Projects/1.launch_save", { project = PR, launch = L, name = "run", data = m })
            r[#r + 1] = run(nil, "Projects/1.variable_save", { project = PR, variable = "v", name = "w", data = m })
            r[#r + 1] = run(nil, "Projects/1.type_config_set", { project = PR, field = "f", value = 3 })
            r[#r + 1] = run(nil, "Projects/1.deploy_save", { project = PR, deploy = m })
            r[#r + 1] = run(WS, "Sdks/1.add", { provider = "ohos", path = "/sdk" })
            r[#r + 1] = run(WS, "Sdks/1.remove", { sdk = SDK })
            assert.same({
                { "publish", WS },
                { "set_intent", P, "shared" },
                { "set_description", L, "t" },
                { "execute_create_profile", CS, m, true },
                { "add_profile_tool", P, "gcc" },
                { "execute_create_config_set", WS, "Dev", m },
                { "execute_create_config_set_from_candidate", WS, "tok" },
                { "execute_edit_config_set", CS, "D2", m },
                { "execute_add_project", WS, "app", "cmake", "app", { mappings = m, tool_entry = m } },
                { "execute_save_configuration", PR, CFG, "Debug", m },
                { "execute_save_launch_config", PR, L, "run", m },
                { "execute_save_variable", PR, "v", "w", m },
                { "save_type_config_field", PR, "f", 3 },
                { "save_deploy", PR, m },
                { "add_sdk", WS, "ohos", "/sdk" },
                { "remove_sdk", WS, SDK },
            }, calls)
            assert.same({ outcome = "ok" }, r[1])
            assert.same({ outcome = "ok", changed = false }, r[3])
            assert.equals(P, r[4].profile)
            assert.same({ outcome = "refused", message = "taken" }, r[6])
            assert.equals(CS, r[7].config_set)
            assert.equals(PR, r[9].project)
            assert.equals(L, r[11].launch)
            assert.equals(SDK, r[15].sdk)
            assert.same({ outcome = "refused", message = "in use" }, r[16])
        end)

        it("runs each deletion target's in-process deletion and reports when it ended", function()
            local plan, ctx = {}, { orphaned_configs = { 1 }, stray_dirs = { 2 } }
            local r = {}
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { profile = P }, confirmed = plan })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { stray_dir = "/w/.nvim/build/x" } })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { orphans = true }, confirmed = ctx })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { project = PR }, confirmed = ctx })
            local unit_done = false
            local unit = { delete = function(_, done) unit_done = true; done() end }
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { unit = unit } })
            assert.equals("execute_deletion", calls[1][1])
            assert.equals(plan, calls[1][2])
            assert.same({ deactivate_profile = P }, calls[1][3])
            assert.same({ "execute_delete_stray_dir", WS, "/w/.nvim/build/x" }, { calls[2][1], calls[2][2], calls[2][3] })
            assert.same({ "execute_orphan_cleanup", WS, { 1 }, { 2 } }, { calls[3][1], calls[3][2], calls[3][3], calls[3][4] })
            assert.same({ "execute_remove_project", WS, PR, ctx }, { calls[4][1], calls[4][2], calls[4][3], calls[4][4] })
            assert.is_true(unit_done)
            -- An orphaned BuildDir: the workspace's deletion of it, its report.
            local seen
            local fake_ws = { delete_orphaned_build_dir = function(_, key, on_done, opts)
                seen = { key, on_done }
                opts.report.kept = { { dir = "d", why = "shared" } }
                local f = {}
                function f:next(fn) fn(true); return f end
                function f:catch() return f end
                return f
            end }
            local got = run(fake_ws, "Maintenance/1.execute_deletion", { target = { build_dir = { rel_path = "build/x" } } })
            assert.same({ "build/x" }, seen)
            assert.same({ outcome = "ok", report = { kept = { { dir = "d", why = "shared" } } } }, got)
            assert.same({ { outcome = "ok" }, { outcome = "refused" }, { outcome = "ok" },
                { outcome = "refused", message = "locked" }, { outcome = "ok" } }, r)
        end)

        it("runs the trust review, the user-prefs deletion, the rescan and the nuke as before", function()
            assert.same({ outcome = "ok", trust = "trusted" }, run(nil, "Workspace/1.trust_accept", {}))
            run(nil, "Workspace/1.delete_user_prefs", { root = "/w" })
            run(WS, "Toolchains/1.rescan", {})
            run(nil, "Maintenance/1.nuke", { root = "/w" })
            assert.same({ { "trust_user_prefs" }, { "delete_user_prefs", "/w" }, { "rescan_tools" },
                { "nuke_cache", "/w" } }, calls)
        end)
    end)

    it("reads an outcome as ok, err (a warn note of an ok is the error shown)", function()
        assert.same({ true }, { model.result({ outcome = "ok" }) })
        assert.same({ false, "no" }, { model.result({ outcome = "refused", message = "no" }) })
        assert.same({ false, "half" },
            { model.result({ outcome = "ok", notes = { "fine", "half" }, note_roles = { "info", "warn" } }) })
    end)

    -- Guard ratchet (5o C0): the status page's sections and dialogs reach
    -- model writes only through ui/model_calls.lua — never the view-model's
    -- write adapters, the command layer, or the loomworks / workspace / unit
    -- write functions themselves.
    it("is the only ui/ file that reaches a model write", function()
        local adapters = { "execute_[%w_]+", "publish", "revert_to_baseline", "publish_one", "revert_one",
            "set_intent", "set_description", "activate_profile", "add_profile_tool", "remove_profile_tool",
            "save_deploy", "save_type_config_field", "add_sdk", "remove_sdk", "resolve_config_set_choice" }
        local patterns = {}
        for _, a in ipairs(adapters) do
            patterns[#patterns + 1] = "%f[%w_]wv%." .. a .. "%("
            patterns[#patterns + 1] = "%f[%w_]workspace_view%." .. a .. "%("
            patterns[#patterns + 1] = 'workspace_view"%)%.' .. a .. "%("
        end
        vim.list_extend(patterns, {
            'require%("loomworks%.model_commands"%)',
            "%.execute_deletion%(", "%.nuke_cache%(", "%.delete_user_prefs%(", "%.trust_user_prefs%(",
            "%.rescan_tools%(", ":delete%(", ":delete_orphaned_build_dir%(", ":ensure_profile%(",
            ":add_sdk%(", ":remove_sdk%(", ":publish%(", ":publish_one%(", ":revert_one%(",
            ":revert_to_baseline%(", ":set_description%(", ":save_[%w_]+%(", ":rename_[%w_]+%(",
            ":delete_[%w_]+%(", ":add_configuration_set%(", ":remove_configuration_set%(", ":add_project%(",
            ":remove_project%(",
        })
        -- Recorded exceptions (file → the exact line), each with its reason:
        -- the Projects section's project-row `D` removes only the project's
        -- declaration, while the catalogue routes a project's removal through
        -- Maintenance/1.execute_deletion { project }, which also deletes its
        -- build directories and downgrades its profiles (the project
        -- browser's removal) — open until it is decided which the row does.
        local allowed = {
            ["lua/loomworks/ui/sections/projects.lua"] = { ["local ok, err = ws:remove_project(proj)"] = true },
        }
        local found = {}
        local base = root .. "/lua/loomworks/ui"
        for _, path in ipairs(vim.fn.globpath(base, "**/*.lua", false, true)) do
            local rel = path:gsub("\\", "/"):match("lua/loomworks/ui/.*$")
            if rel ~= "lua/loomworks/ui/model_calls.lua" then
                local fh = assert(io.open(path, "r"))
                local n = 0
                for line in fh:lines() do
                    n = n + 1
                    if not line:match("^%s*%-%-") and not (allowed[rel] or {})[vim.trim(line)] then
                        for _, pat in ipairs(patterns) do
                            if line:find(pat) then
                                found[#found + 1] = rel .. ":" .. n .. ": " .. vim.trim(line)
                                break
                            end
                        end
                    end
                end
                fh:close()
            end
        end
        assert.same({}, found)
    end)
end)
