--- loomworks.lsp_source: where the editor's LSP layer reads the LSP
--- configuration state (spec §9.2 "Where the entries come from", daemon.md
--- §19.16 "LSP configuration"). Today only the in-process source exists: the
--- state built by loomworks/lsp_config.lua from the `loomworks` facade's model.
--- The facade is overridden per test.

local lsp_config = require("loomworks.lsp_config")
local source = require("loomworks.lsp_source")
local lw = require("loomworks")

local FACADE = { "get_workspace", "get_projects", "lsp_ready", "project_for_buf",
    "get_setup_error", "get_lsp_options" }

--- A fake workspace whose active profile maps project keys to build dirs.
local function fake_ws(map, ready)
    local ws = { root = "/ws", _lsp_ready = ready ~= false, _config_units = {} }
    local profile = {
        key = "dbg",
        project = function(_, key)
            local bd = map[key]
            if not bd then return nil end
            return {
                build_dir = function() return bd end,
                config_key = function() return "Debug" end,
                status = function() return "configured" end,
                configured_here = function() return true end,
            }
        end,
    }
    function ws:get_active_profile() return profile end
    function ws:lsp_option_servers() return { "clangd" } end
    function ws:get_lsp_options(server) return { server = server } end
    return ws
end

--- A fake project whose module emits one entry per server in `servers`.
local function fake_project(ws, key, servers)
    local p = { key = key, path = key, _workspace = ws }
    p._module = { impl = { lsp_configs = function()
        local out = {}
        for _, s in ipairs(servers) do
            out[#out + 1] = { server = s, root_dir = "/ws/" .. key }
        end
        return out
    end } }
    return p
end

describe("lsp_source (in-process)", function()
    local saved, ws, projects

    before_each(function()
        lsp_config.clear_memo()
        saved = {}
        for _, k in ipairs(FACADE) do saved[k] = lw[k] end
        ws = fake_ws({ A = "/ws/b/A", B = "/ws/b/B" })
        projects = {
            B = fake_project(ws, "B", { "clangd" }),
            A = fake_project(ws, "A", { "clangd", "qmlls" }),
        }
        ws._projects = projects
        lw.get_workspace = function() return ws end
        lw.get_projects = function() return projects end
        lw.lsp_ready = function() return true end
        lw.get_setup_error = function() return nil end
    end)

    after_each(function()
        for _, k in ipairs(FACADE) do lw[k] = saved[k] end
        lsp_config.clear_memo()
    end)

    it("state is the LspConfig/1 get shape of the facade's model", function()
        local st = source.state()
        assert.equals("loaded", st.state)
        assert.is_true(st.ready)
        assert.same({ "A", "B" }, vim.tbl_map(function(r) return r.project end, st.projects))
        assert.same({ clangd = { server = "clangd" } }, st.options)
        local e = lsp_config.entry(st.projects[1], "clangd")
        assert.equals("/ws/b/A", e.db_dir)
        assert.equals(0, e.db_rev)
        assert.is_true(source.loaded())
        assert.equals("/ws", source.root())
    end)

    it("state without a workspace is unloaded, or error after a setup error", function()
        lw.get_workspace = function() return nil end
        assert.same({ state = "unloaded", ready = false, projects = {}, options = {} }, source.state())
        lw.get_setup_error = function() return "boom" end
        assert.equals("error", source.state().state)
        assert.same({}, source.projects())
        assert.is_false(source.loaded())
        assert.is_nil(source.root())
    end)

    it("project_for_buf maps a buffer through the facade to its record", function()
        lw.project_for_buf = function(bufnr) return bufnr == 7 and projects.B or nil end
        local rec = source.project_for_buf(7)
        assert.equals("B", rec.project)
        assert.equals("/ws/B", rec.entries[1].root_dir)
        assert.equals("/ws/b/B", rec.entries[1].db_dir)
        assert.is_nil(source.project_for_buf(8))
        lw.project_for_buf = nil
        assert.is_nil(source.project_for_buf(7))
    end)

    it("find_by_root finds the record and entry of a server by root_dir", function()
        local rec, entry = source.find_by_root("qmlls", "/ws/A/")
        assert.equals("A", rec.project)
        assert.equals("qmlls", entry.server)
        local none_rec, none_entry = source.find_by_root("qmlls", "/ws/B")
        assert.is_nil(none_rec)
        assert.is_nil(none_entry)
        assert.is_nil((source.find_by_root("clangd", nil)))
    end)

    it("loaded_and_ready needs a loaded workspace and reported readiness", function()
        assert.is_true(source.loaded_and_ready())
        assert.is_false(source.pending())

        lw.lsp_ready = function() return false end
        assert.is_false(source.loaded_and_ready())
        assert.is_true(source.pending())

        -- Ready but nothing loaded: a buffer must still be held.
        lw.lsp_ready = function() return true end
        lw.get_workspace = function() return nil end
        assert.is_false(source.loaded_and_ready())
        assert.is_false(source.pending())
    end)

    it("options come from the facade, nil when it offers none", function()
        lw.get_lsp_options = function(server) return { server = server, x = 1 } end
        assert.same({ server = "clangd", x = 1 }, source.options("clangd"))
        lw.get_lsp_options = nil
        assert.is_nil(source.options("clangd"))
    end)
end)
