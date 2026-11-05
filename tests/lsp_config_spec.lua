--- loomworks.lsp_config: the host-neutral LSP configuration state (spec §9.2
--- "Where the entries come from", daemon.md §19.20 `LspConfig/1`): the
--- state's shape and project order, db_state derivation, the core
--- `db_dir`, `db_rev` and the content memo.

local lsp_config = require("loomworks.lsp_config")

--- A fake workspace whose active profile maps project keys to
--- { build_dir, configured } and whose options come from `opts`.
local function fake_ws(map, extra)
    local ws = { root = "/ws", _lsp_ready = true, _config_units = {} }
    local profile = {
        key = "dbg",
        project = function(_, key)
            local m = map[key]
            if not m then return nil end
            return {
                build_dir = function() return m.build_dir end,
                config_key = function() return "Debug" end,
                status = function() return m.configured and "configured" or "unconfigured" end,
                configured_here = function() return m.configured == true end,
            }
        end,
    }
    function ws:get_active_profile() return profile end
    function ws:lsp_option_servers() return { "clangd" } end
    function ws:get_lsp_options(server)
        return { server = server, clang_tidy = true }
    end
    for k, v in pairs(extra or {}) do ws[k] = v end
    return ws
end

--- A fake project whose module emits `emit()`; counts lsp_configs calls.
local function fake_project(ws, key, emit)
    local p = { key = key, path = key, _workspace = ws, calls = 0 }
    p._module = { impl = { lsp_configs = function(proj)
        proj.calls = proj.calls + 1
        return emit(proj)
    end } }
    return p
end

local function clangd_entry(root)
    return { { server = "clangd", root_dir = root, compile_commands_dir = root .. "/db" } }
end

describe("lsp_config", function()
    before_each(function() lsp_config.clear_memo() end)

    it("an absent workspace is the given state, not ready, empty", function()
        assert.same({ state = "unloaded", ready = false, projects = {}, options = {} },
            lsp_config.state(nil))
        assert.same({ state = "error", ready = false, projects = {}, options = {} },
            lsp_config.state(nil, { state = "error" }))
    end)

    it("builds the get shape with projects in ascending key order", function()
        local ws = fake_ws({ A = { build_dir = "/ws/b/A", configured = true } })
        ws._projects = {
            fake_project(ws, "Zed", function() return clangd_entry("/ws/Zed") end),
            fake_project(ws, "A", function() return clangd_entry("/ws/A") end),
            fake_project(ws, "Mid", function() return {} end),
        }
        local st = lsp_config.state(ws, { id_of = function(p) return "id-" .. p.key end })
        assert.equals("loaded", st.state)
        assert.is_true(st.ready)
        assert.same({ clangd = { server = "clangd", clang_tidy = true } }, st.options)
        assert.same({ "A", "Mid", "Zed" }, vim.tbl_map(function(r) return r.project end, st.projects))
        local a = st.projects[1]
        assert.equals("id-A", a.id)
        assert.equals("A", a.path)
        assert.same({
            server = "clangd", root_dir = "/ws/A", compile_commands_dir = "/ws/A/db",
            db_state = "ready", db_dir = "/ws/b/A", db_rev = 0,
        }, a.entries[1])
        assert.same({}, st.projects[2].entries)
        -- No active build dir: db_dir absent, db_state unconfigured.
        assert.is_nil(st.projects[3].entries[1].db_dir)
        assert.equals("unconfigured", st.projects[3].entries[1].db_state)
    end)

    it("reports not ready while the owned databases are pending", function()
        local ws = fake_ws({}, { _lsp_ready = false })
        ws._projects = {}
        assert.is_false(lsp_config.state(ws).ready)
    end)

    it("derives db_state only where the module omitted it", function()
        local ws = fake_ws({ P = { build_dir = "/ws/b/P", configured = false } })
        local p = fake_project(ws, "P", function()
            return {
                { server = "clangd", root_dir = "/ws/P" },
                { server = "other", root_dir = "/ws/P", db_state = "ready" },
            }
        end)
        local entries = lsp_config.entries(ws, p)
        assert.equals("unconfigured", entries[1].db_state)
        assert.equals("ready", entries[2].db_state)
    end)

    it("leaves db_state alone for a project without a workspace", function()
        local p = fake_project(nil, "P", function() return clangd_entry("/ws/P") end)
        assert.is_nil(lsp_config.entries(nil, p)[1].db_state)
    end)

    it("passes a module's own build_dir through and defaults db_dir to the active dir", function()
        local ws = fake_ws({ P = { build_dir = "/ws/b/P", configured = true } })
        local p = fake_project(ws, "P", function()
            return { { server = "qmlls", root_dir = "/ws/P", build_dir = "/ws/b/Other" } }
        end)
        local e = lsp_config.entries(ws, p)[1]
        assert.equals("/ws/b/Other", e.build_dir, "the module's field is never overwritten")
        assert.equals("/ws/b/P", e.db_dir)
    end)

    it("keeps a module's db_dir and keys db_rev by it (a redirect)", function()
        local ws = fake_ws({ P = { build_dir = "/ws/b/P", configured = true } })
        local p = fake_project(ws, "P", function()
            return { { server = "clangd", root_dir = "/ws/P", db_dir = "/ws/b/Target" } }
        end)
        local first = lsp_config.entries(ws, p)
        assert.equals("/ws/b/Target", first[1].db_dir)
        assert.is_nil(first[1].build_dir, "core sets no build_dir")
        lsp_config.bump_db_rev(ws, "/ws/b/P")
        assert.equals(0, lsp_config.entries(ws, p)[1].db_rev, "the active dir's write is not this entry's")
        lsp_config.bump_db_rev(ws, "/ws/b/Target")
        assert.equals(1, lsp_config.entries(ws, p)[1].db_rev, "the redirect target's write is")
    end)

    it("raises db_rev per written db_dir, visible on a memo hit", function()
        local ws = fake_ws({ P = { build_dir = "/ws/b/P", configured = true } })
        local p = fake_project(ws, "P", function() return clangd_entry("/ws/P") end)
        local first = lsp_config.entries(ws, p)
        assert.equals(0, first[1].db_rev)
        lsp_config.bump_db_rev(ws, "/ws/b/P")
        lsp_config.bump_db_rev(ws, "/ws/b/P/")
        lsp_config.bump_db_rev(ws, "/ws/b/Q")
        local second = lsp_config.entries(ws, p)
        assert.equals(1, p.calls, "a written database is no memo determinant")
        assert.equals(first[1], second[1], "entries are identity-stable across hits")
        assert.equals(2, second[1].db_rev)
        assert.equals(1, lsp_config.db_rev(ws, "/ws/b/Q"))
        assert.equals(0, lsp_config.db_rev(ws, nil))
        assert.equals(0, lsp_config.db_rev(nil, "/ws/b/P"))
    end)

    it("memoizes on content and recomputes when a determinant moves", function()
        local map = { P = { build_dir = "/ws/b/P", configured = false } }
        local ws = fake_ws(map)
        local p = fake_project(ws, "P", function() return clangd_entry("/ws/P") end)
        lsp_config.entries(ws, p)
        lsp_config.entries(ws, p)
        assert.equals(1, p.calls)
        map.P.configured = true -- status is part of the key
        assert.equals("ready", lsp_config.entries(ws, p)[1].db_state)
        assert.equals(2, p.calls)
        lsp_config.bump_generation()
        lsp_config.entries(ws, p)
        assert.equals(3, p.calls)
        p.type_config = { clangd = "/opt/clangd", list = { 1, 2 } }
        lsp_config.entries(ws, p)
        lsp_config.entries(ws, p)
        assert.equals(4, p.calls)
        lsp_config.clear_memo()
        lsp_config.entries(ws, p)
        assert.equals(5, p.calls)
    end)

    it("keeps at most ENV_SLOTS environments per project, least recently used dropped first", function()
        local ws = fake_ws({ P = { build_dir = "/ws/b/P", configured = true } })
        local p = fake_project(ws, "P", function() return clangd_entry("/ws/P") end)
        local function env(i) return "PATH=/bin" .. i .. "\n" .. string.rep("X=y\n", 500) end
        for i = 1, lsp_config.ENV_SLOTS do lsp_config.entries(ws, p, env(i)) end
        assert.equals(lsp_config.ENV_SLOTS, p.calls)
        -- Each environment is a hit while it is kept.
        for i = 1, lsp_config.ENV_SLOTS do lsp_config.entries(ws, p, env(i)) end
        assert.equals(lsp_config.ENV_SLOTS, p.calls)
        -- Touch env(1) (now the most recent): a new environment then evicts
        -- the least recently used one, env(2).
        lsp_config.entries(ws, p, env(1))
        lsp_config.entries(ws, p, env(99))
        assert.equals(lsp_config.ENV_SLOTS + 1, p.calls)
        assert.equals(lsp_config.ENV_SLOTS, lsp_config._memo_slot_count("P"))
        lsp_config.entries(ws, p, env(1))
        assert.equals(lsp_config.ENV_SLOTS + 1, p.calls, "env(1) kept (recently used)")
        lsp_config.entries(ws, p, env(2))
        assert.equals(lsp_config.ENV_SLOTS + 2, p.calls, "env(2) evicted (least recently used)")
        -- Many environments never grow the memo past the bound.
        for i = 100, 140 do lsp_config.entries(ws, p, env(i)) end
        assert.equals(lsp_config.ENV_SLOTS, lsp_config._memo_slot_count("P"))
        -- The editor's own (no env_key) is just another slot; invalidation
        -- still reaches every kept environment.
        lsp_config.entries(ws, p)
        local before = p.calls
        lsp_config.entries(ws, p)
        lsp_config.entries(ws, p, env(140))
        assert.equals(before, p.calls)
        lsp_config.bump_generation()
        lsp_config.entries(ws, p)
        lsp_config.entries(ws, p, env(140))
        assert.equals(before + 2, p.calls)
    end)

    it("names an environment by a short stable digest, never the signature itself", function()
        local sig = "PATH=/usr/bin\n" .. string.rep("LONG=value\n", 1000)
        local d = lsp_config._env_digest(sig)
        assert.equals(64, #d)
        assert.equals(d, lsp_config._env_digest(sig))
        assert.are_not.equal(d, lsp_config._env_digest(sig .. "Z=1\n"))
        assert.equals("", lsp_config._env_digest(nil))
        local p = fake_project(fake_ws({}), "P", function() return {} end)
        local key = lsp_config._memo_key(p, sig)
        assert.is_nil(key:find("LONG=value", 1, true))
        assert.is_truthy(key:find(d, 1, true))
    end)

    it("returns no entries when lsp_configs fails or is absent", function()
        local ws = fake_ws({})
        local bad = fake_project(ws, "B", function() error("boom") end)
        assert.same({}, lsp_config.entries(ws, bad))
        assert.same({}, lsp_config.entries(ws, { key = "N", _module = { impl = {} } }))
    end)

    it("entry finds the first entry of a server in a list or a record", function()
        local rec = { project = "P", entries = {
            { server = "qmlls", root_dir = "/q" }, { server = "clangd", root_dir = "/c1" },
            { server = "clangd", root_dir = "/c2" },
        } }
        assert.equals("/c1", lsp_config.entry(rec, "clangd").root_dir)
        assert.equals("/q", lsp_config.entry(rec.entries, "qmlls").root_dir)
        assert.is_nil(lsp_config.entry(rec, "none"))
        assert.is_nil(lsp_config.entry(nil, "clangd"))
    end)

    it("norm folds separators and trailing slashes", function()
        assert.equals(lsp_config.norm("/a/b"), lsp_config.norm("/a/b/"))
        assert.equals(lsp_config.norm("/a/b"), lsp_config.norm("\\a\\b"))
    end)
end)
