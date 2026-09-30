--- Health scope and areas (headless §16.36): relevance of contributors,
--- declarations and results; the relevant-scope probe (skipped declarations,
--- partial tier); the not-checked rule of a partial tier; the union/active
--- split; area-narrowed tier writes; the CLI's area validation, dispatch and
--- completion.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local inv = require("loomworks.inventory")

--- A fake module domain object.
local function module(id, impl)
    impl = impl or {}
    return {
        id = id, impl = impl, languages = impl.languages,
        caches_cpp = function(self)
            for _, l in ipairs(self.languages or {}) do
                if l == "c" or l == "c++" then return true end
            end
            return false
        end,
    }
end

--- A fake project of `mod`.
local function project(key, mod)
    return { key = key, type = mod.id, _module = mod, _configurations = {} }
end

--- Contributors as `inventory.contributors()` returns them.
local CONTRIBUTORS = {
    { kind = "module", id = "cmake", impl = { languages = { "c", "c++" }, lsp_servers = { "clangd", "qmlls" } } },
    { kind = "module", id = "meson", impl = { languages = { "c++", "c" }, lsp_servers = { "clangd" } } },
    { kind = "module", id = "typescript", impl = { languages = { "typescript" }, lsp_servers = {} } },
    { kind = "sdk", id = "ohos", impl = {} },
    { kind = "integration", id = "clangd", impl = { languages = { "c", "c++" } } },
    { kind = "integration", id = "qmlls", impl = { languages = { "qml" } } },
    { kind = "integration", id = "codelldb", impl = { languages = { "c", "c++", "rust" } } },
    { kind = "integration", id = "pwa_node", impl = { languages = { "typescript", "javascript" } } },
}

describe("health scope — relevance (§16.36)", function()
    local saved
    before_each(function()
        saved = inv._contributors
        inv._contributors = CONTRIBUTORS
    end)
    after_each(function() inv._contributors = saved end)

    local function cmake_ws()
        local cmake = module("cmake", CONTRIBUTORS[1].impl)
        return { _projects = { project("App", cmake) }, _profiles = {} }
    end

    it("collects the modules, languages, servers and C/C++ caching of the projects", function()
        local rel = inv.relevance(cmake_ws())
        assert.is_false(rel.none)
        assert.is_true(rel.modules["module:cmake"])
        assert.is_nil(rel.modules["module:meson"])
        assert.is_true(rel.languages["c++"])
        assert.is_true(rel.lsp_servers.qmlls)
        assert.is_true(rel.cxx)
        assert.is_true(rel.plugin_ids["module:cmake"])
        assert.is_true(rel.plugin_ids["integration:clangd"])
        assert.is_nil(rel.plugin_ids["integration:pwa_node"])
        assert.is_true(inv.relevance(nil).none)
    end)

    it("decides each declaration's relevance, shared ids relevant through any declarer", function()
        local rel = inv.relevance(cmake_ws())
        local function r(d) return (inv.declaration_relevant(rel, d)) end
        assert.is_false(r({ id = "exe:meson", contributors = { "module:meson" } }))
        assert.is_false(r({ id = "exe:node", contributors = { "module:typescript", "integration:pwa_node" } }))
        assert.is_true(r({ id = "exe:ninja", contributors = { "module:cmake", "module:meson" } }))
        assert.is_true(r({ id = "exe:ninja", contributors = { "module:meson", "module:cmake" } }))
        -- An unpinned SDK provider is not probed.
        assert.is_false(r({ id = "sdks:ohos", contributors = { "core" }, category = "SDKs" }))
        -- Whole-relevant: lw, compiler caches (C/C++ workspace), matched companions.
        assert.same({ true, true }, { inv.declaration_relevant(rel, { id = "lw", contributors = { "core" } }) })
        assert.same({ true, true }, { inv.declaration_relevant(rel,
            { id = "exe:sccache", category = "compiler caches", contributors = { "core" } }) })
        assert.same({ true, true }, { inv.declaration_relevant(rel,
            { id = "lsp:qmlls", category = "language servers", contributors = { "integration:qmlls" } }) })
        assert.same({ true, true }, { inv.declaration_relevant(rel,
            { id = "dap:codelldb", category = "debug adapters", contributors = { "integration:codelldb" } }) })
        -- A declaration's own languages narrow it further.
        assert.is_false(r({ id = "x", contributors = { "module:cmake" }, languages = { "rust" } }))
        -- Outside a workspace only lw (and the registry, for rejected plugins).
        local none = inv.relevance(nil)
        assert.is_true((inv.declaration_relevant(none, { id = "lw" })))
        assert.is_true((inv.declaration_relevant(none, { id = "plugins" })))
        assert.is_false((inv.declaration_relevant(none, { id = "exe:cmake", contributors = { "module:cmake" } })))
    end)

    it("matches a language server by the modules' lsp_servers, not its languages", function()
        local ts = module("typescript", CONTRIBUTORS[3].impl)
        local rel = inv.relevance({ _projects = { project("Web", ts) }, _profiles = {} })
        -- typescript declares lsp_servers = {}: clangd is not relevant even though
        -- no language mismatch rule would be needed; pwa_node matches by language.
        assert.is_false((inv.declaration_relevant(rel,
            { id = "lsp:clangd", category = "language servers", contributors = { "integration:clangd" } })))
        assert.is_true((inv.declaration_relevant(rel,
            { id = "dap:pwa-node", category = "debug adapters", contributors = { "integration:pwa_node" } })))
        assert.is_false(rel.cxx)
    end)
end)

describe("health scope — probing (§16.36)", function()
    local saved_c, saved_d
    local probed
    local function decl(id, category, contributors)
        return { id = id, category = category, label = id, contributors = contributors,
            probe = function(_, done)
                probed[id] = true
                done({ id = id, label = id, status = "found" })
            end }
    end
    before_each(function()
        probed = {}
        saved_c, saved_d = inv._contributors, inv.declarations
        inv._contributors = CONTRIBUTORS
        inv.declarations = function()
            return {
                decl("exe:cmake", "build tools", { "module:cmake" }),
                decl("exe:meson", "build tools", { "module:meson" }),
                decl("exe:node", "build tools", { "module:typescript", "integration:pwa_node" }),
                decl("lsp:clangd", "language servers", { "integration:clangd" }),
                decl("lw", "lw", { "core" }),
            }
        end
    end)
    after_each(function() inv._contributors, inv.declarations = saved_c, saved_d end)

    local function cmake_ws()
        return { _projects = { project("App", module("cmake", CONTRIBUTORS[1].impl)) }, _profiles = {} }
    end

    it("the relevant scope probes only relevant declarations and records a partial tier", function()
        local tier = inv.probe_tier(cmake_ws(), { scope = "relevant", ctx = { timeout_ms = 1000 } })
        assert.is_true(probed["exe:cmake"])
        assert.is_true(probed["lsp:clangd"])
        assert.is_true(probed["lw"])
        assert.is_nil(probed["exe:meson"])
        assert.is_nil(probed["exe:node"])
        assert.same({ toolchains = 2 }, tier.skipped)
        assert.same({ "core", "integration:clangd", "module:cmake" }, tier.contributors)
    end)

    it("the full scope probes everything and writes no contributor list", function()
        local tier = inv.probe_tier(cmake_ws(), { scope = "all", ctx = { timeout_ms = 1000 } })
        assert.is_true(probed["exe:meson"])
        assert.is_true(probed["exe:node"])
        assert.is_nil(tier.contributors)
        assert.is_nil(tier.skipped)
    end)

    it("an area selection probes only those areas, uncounted", function()
        local tier = inv.probe_tier(cmake_ws(), { scope = "all", areas = { editor = true }, ctx = { timeout_ms = 1000 } })
        assert.is_true(probed["lsp:clangd"])
        assert.is_nil(probed["exe:cmake"])
        assert.is_nil(probed["lw"])
        assert.is_nil(tier.skipped)
        assert.same({ "integration:clangd" }, tier.contributors)
    end)

    it("outside a workspace the relevant scope probes lw only", function()
        local tier = inv.probe_tier(nil, { scope = "relevant", ctx = { timeout_ms = 1000 } })
        assert.same({ lw = true }, probed)
        assert.same({ toolchains = 3, editor = 1 }, tier.skipped)
    end)
end)

describe("health scope — classification (§16.36)", function()
    it("a partial tier reads an unprobed contributor's requirement as not checked", function()
        local req = { id = "exe:meson", label = "meson", contributors = { "module:meson" }, required_by = { "App" } }
        local partial = { results = {}, declared = {}, contributors = { "core", "module:cmake" } }
        local e = inv.classify(partial, { req })[1]
        assert.equals("unknown", e.status)
        assert.matches("not checked", e.detail, 1, true)
        assert.same({}, inv.suggestions_for({ e }))
        -- A full tier (no contributor list) still says missing.
        local full = inv.classify({ results = {}, declared = {} }, { req })[1]
        assert.equals("missing", full.status)
        -- A partial tier that probed the contributor says missing too.
        local probed = inv.classify({ results = {}, declared = {}, contributors = { "module:meson" } }, { req })[1]
        assert.equals("missing", probed.status)
        assert.equals("toolchains", inv.area_of("build tools"))
    end)

    it("relevance spans every profile; required stays the active profile's", function()
        local cmake = module("cmake", {
            languages = { "c++" },
            health_requirements = function(ctx)
                return { { id = "cxx:" .. ctx.tool.data.name, label = ctx.tool.data.name, via = "compilers:path" } }
            end,
        })
        local app = project("App", cmake)
        local function profile(key, tool)
            return {
                key = key,
                projects = function()
                    return { {
                        _project = app,
                        tool_object = function() return { data = { name = tool } } end,
                        configuration = function() return nil end,
                    } }
                end,
            }
        end
        local dev, asan = profile("dev", "gcc"), profile("asan", "clang")
        local ws = { _projects = { app }, _profiles = { dev, asan }, _active_profile = dev }
        local tier = {
            declared = { { id = "compilers:path", category = "compilers", contributors = { "module:cmake" } } },
            results = {
                { id = "cxx:gcc", label = "gcc", status = "found", category = "compilers", decl = "compilers:path" },
                { id = "cxx:clang", label = "clang", status = "found", category = "compilers", decl = "compilers:path" },
                { id = "cxx:icc", label = "icc", status = "found", category = "compilers", decl = "compilers:path" },
            },
        }
        local saved = inv._contributors
        inv._contributors = CONTRIBUTORS
        local by = {}
        for _, e in ipairs(inv.scoped_entries(tier, ws)) do by[e.id] = e end
        inv._contributors = saved
        assert.is_true(by["cxx:gcc"].required)
        assert.is_true(by["cxx:gcc"].relevant)
        assert.same({ "dev/App" }, by["cxx:gcc"].required_by)
        assert.is_false(by["cxx:clang"].required)
        assert.is_true(by["cxx:clang"].relevant)
        assert.same({ "asan/App" }, by["cxx:clang"].used_by)
        assert.is_false(by["cxx:icc"].relevant)
        assert.equals("toolchains", by["cxx:icc"].area)
    end)
end)

describe("health scope — tier writes under an area selection (§16.36)", function()
    local suggestions = require("loomworks.suggestions")
    local health_cache = require("loomworks.health_cache")

    local function mem_io()
        local store = {}
        return {
            store = store,
            read_json = function(path)
                local c = store[path]
                if not c then return nil, "enoent" end
                return vim.json.decode(c)
            end,
            write_json = function(path, tbl) store[path] = vim.json.encode(tbl); return true end,
            ensure_dir = function() return true end,
        }
    end

    local saved
    before_each(function()
        saved = { p = suggestions._providers, h = suggestions._health_providers, a = suggestions._areas,
            lk = suggestions._local_key, nk = suggestions._network_key, c = suggestions._clock }
        suggestions._local_key = function() return "k" end
        suggestions._network_key = function() return "n" end
        suggestions._clock = function() return 7 end
    end)
    after_each(function()
        suggestions._providers, suggestions._health_providers, suggestions._areas = saved.p, saved.h, saved.a
        suggestions._local_key, suggestions._network_key, suggestions._clock = saved.lk, saved.nk, saved.c
    end)

    it("writes only the tiers the selection computed completely", function()
        local io_dep = mem_io()
        local ws = { root = "/r", _core = { _deps = { io = io_dep } }, _projects = {} }
        local cache_fn = function() return { { title = "C" } } end
        local lw_fn = function() return { { title = "U" } } end
        suggestions._providers = { cache_fn }
        suggestions._health_providers = { lw_fn }
        suggestions._areas = { [cache_fn] = "cache", [lw_fn] = "lw" }
        local tier = { results = {}, declared = {}, key = "x", skipped = { toolchains = 1 } }

        -- Narrowed to `cache`: the local tier only; the lw provider did not run.
        local out = suggestions.collect_health(ws, { inventory = tier, areas = { cache = true } })
        assert.equals(1, #out)
        assert.equals("cache", out[1].area)
        local data = health_cache.read(io_dep, "/r")
        assert.is_not_nil(data.local_tier)
        assert.is_nil(data.network_tier)
        assert.is_nil(data.inventory_tier)

        -- Unnarrowed: every tier; the per-run hidden counts are not cached.
        suggestions.collect_health(ws, { inventory = tier })
        data = health_cache.read(io_dep, "/r")
        assert.equals("U", data.network_tier.items[1].title)
        assert.equals("lw", data.network_tier.items[1].area)
        assert.equals("x", data.inventory_tier.key)
        assert.is_nil(data.inventory_tier.skipped)
    end)
end)

describe("health scope — CLI (§16.36)", function()
    local cli = require("loomworks.cli")

    local function capture(fn)
        local out_buf, err_buf = {}, {}
        local rw, rs, rex = io.write, io.stderr, os.exit
        io.write = function(...) for _, s in ipairs({ ... }) do out_buf[#out_buf + 1] = s end end
        io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
        local exit_code
        os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
        local ok, err = pcall(fn)
        io.write, io.stderr, os.exit = rw, rs, rex
        if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
        return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
    end

    after_each(function() cli._reset_modes() end)

    it("validates and deduplicates areas", function()
        assert.same({ "cache", "lw" }, cli._health_areas({ "cache", "lw", "cache" }))
        local ok, bad = cli._health_areas({ "lw", "compilers" })
        assert.is_nil(ok)
        assert.equals("compilers", bad)
    end)

    it("an unknown area is a usage error naming the areas", function()
        local saved_arg = _G.arg
        _G.arg = { "health", "compilers" }
        local r = capture(function() cli.main() end)
        _G.arg = saved_arg
        assert.equals(1, r.exit_code)
        assert.matches("unknown health area 'compilers'", r.stderr, 1, true)
        assert.matches("toolchains", r.stderr, 1, true)
    end)

    it("completion offers the areas not yet given, then the flags", function()
        local r = capture(function() cli.cmd_complete(2, { "lw", "health", "" }) end)
        assert.matches("toolchains\n", r.stdout, 1, true)
        assert.matches("--all\n", r.stdout, 1, true)
        local r2 = capture(function() cli.cmd_complete(3, { "lw", "health", "toolchains", "" }) end)
        assert.is_nil(r2.stdout:find("toolchains", 1, true))
        assert.matches("cache\n", r2.stdout, 1, true)
    end)

    it("lw help health lists every area", function()
        local r = capture(function() cli.cmd_help("health") end)
        for _, a in ipairs(inv.AREAS) do
            assert.is_truthy(r.stdout:find("\n  " .. a .. " ", 1, true), a)
        end
        assert.matches("--all", r.stdout, 1, true)
    end)
end)
