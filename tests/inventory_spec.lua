--- Tests for the environment inventory framework (headless §16.33): dedupe,
--- timeout/error → unknown, category order, enumerating probes, the cached
--- inventory tier (key match / mismatch; the passive path never probes), the
--- environment key, and the plugin registry (rejected plugins). No test depends
--- on the host's PATH, compilers or compiler caches.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local inv = require("loomworks.inventory")

--- A probe context with everything injected: nothing on PATH unless listed,
--- `run` answers from `outputs[argv[1]]`, files from `files`.
local function fake_ctx(opts)
    opts = opts or {}
    local on_path = opts.path or {}
    local outputs = opts.outputs or {}
    local files = opts.files or {}
    local ran = {}
    local ctx = inv.context(opts.workspace, {
        platform = opts.platform or "linux",
        lookup = function(name) return on_path[name] end,
        run = function(argv, cb)
            ran[#ran + 1] = argv
            cb({ code = 0, stdout = outputs[argv[1]] or "", stderr = "" })
        end,
        read_file = function(p) return files[p] end,
        exists = function(p) return files[p] ~= nil end,
        getenv = function(k) return (opts.env or {})[k] end,
        stdpath_data = opts.stdpath_data or false,
        timeout_ms = opts.timeout_ms or 2000,
    })
    ctx._ran = ran
    return ctx
end

--- Probe a declaration list and return results keyed by id.
local function probe(decls, ctx)
    local results = inv.probe_all(decls, ctx)
    local by = {}
    for _, r in ipairs(results) do by[r.id] = r end
    return by, results
end

-- ---------------------------------------------------------------------------
-- Framework
-- ---------------------------------------------------------------------------
describe("inventory framework", function()
    local saved
    before_each(function() saved = inv._contributors end)
    after_each(function() inv._contributors = saved end)

    it("dedupes declarations by id — probed once, listed once", function()
        local calls = 0
        local function decl()
            return { id = "exe:shared", category = "build tools", label = "shared",
                probe = function(_, done) calls = calls + 1; done({ status = "found" }) end }
        end
        inv._contributors = {
            { kind = "module", id = "a", api = 1, impl = { health_inventory = function() return { decl() } end } },
            { kind = "module", id = "b", api = 1, impl = { health_inventory = function() return { decl() } end } },
        }
        local ctx = fake_ctx()
        local decls = inv.declarations(ctx)
        local n = 0
        for _, d in ipairs(decls) do if d.id == "exe:shared" then n = n + 1 end end
        assert.equals(1, n)
        local by = probe(decls, ctx)
        assert.equals(1, calls)
        assert.equals("found", by["exe:shared"].status)
    end)

    it("a probe that never answers reads unknown after the timeout", function()
        local ctx = fake_ctx({ timeout_ms = 50 })
        local by = probe({ { id = "slow", category = "build tools", label = "slow",
            probe = function() end } }, ctx)
        assert.equals("unknown", by.slow.status)
        assert.is_truthy(by.slow.detail:find("timed out", 1, true))
    end)

    it("a probe that errors reads unknown and never fails the report", function()
        local ctx = fake_ctx()
        local by = probe({
            { id = "boom", category = "build tools", label = "boom", probe = function() error("x") end },
            { id = "ok", category = "build tools", label = "ok", probe = function(_, d) d({ status = "found" }) end },
        }, ctx)
        assert.equals("unknown", by.boom.status)
        assert.equals("found", by.ok.status)
    end)

    it("an enumerating probe yields one result per installation", function()
        local ctx = fake_ctx()
        local by, list = probe({ { id = "compilers:x", category = "compilers", label = "x",
            probe = function(_, done)
                done({ { id = "cxx:/a", label = "A", status = "found" },
                       { id = "cxx:/b", label = "B", status = "found" } })
            end } }, ctx)
        assert.equals(2, #list)
        assert.equals("compilers", by["cxx:/a"].category)
        assert.equals("compilers:x", by["cxx:/b"].decl)
    end)

    it("classify orders by the fixed category order; unknown categories → other", function()
        local tier = { results = {
            { id = "lw", label = "lw", status = "found", category = "lw" },
            { id = "z", label = "z", status = "found", category = "weird" },
            { id = "c", label = "c", status = "found", category = "compilers" },
            { id = "b", label = "b", status = "found", category = "build tools" },
        }, declared = {} }
        local cats = {}
        for _, e in ipairs(inv.classify(tier, {})) do cats[#cats + 1] = e.category end
        -- "weird" was stored as-is here; probe_all maps unknown categories to
        -- "other", classify sorts unrecognized ones last.
        assert.same({ "build tools", "compilers", "lw", "weird" }, cats)
        local ctx = fake_ctx()
        local by = probe({ { id = "q", category = "nonsense", label = "q",
            probe = function(_, d) d({ status = "found" }) end } }, ctx)
        assert.equals("other", by.q.category)
    end)

    it("norm_path/path_id normalize slashes and (Windows) case", function()
        assert.equals("c:/tools/g++.exe", inv.norm_path("C:\\Tools\\g++.exe", true))
        assert.equals("/Usr/bin/g++", inv.norm_path("/Usr/bin/g++", false))
    end)
end)

-- ---------------------------------------------------------------------------
-- Cached inventory tier (§16.33): passive collect never probes
-- ---------------------------------------------------------------------------
describe("inventory cache tier", function()
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

    -- A workspace backed by an in-memory io with one project whose module
    -- requires `exe:tool`.
    local function fake_ws(io_dep)
        local project = { key = "App", _module = { impl = {
            health_requirements = function() return { { id = "exe:tool", label = "tool", hint = "get tool" } } end,
        } } }
        return { root = "/root", _core = { _deps = { io = io_dep } }, _projects = { project },
            _profiles = {}, _active_profile = nil }
    end

    local saved
    before_each(function()
        saved = {
            providers = suggestions._providers, health = suggestions._health_providers,
            key = inv.environment_key, probe_tier = inv.probe_tier, probe_all = inv.probe_all,
            declarations = inv.declarations, network_key = suggestions._network_key,
        }
        suggestions._providers = {}
        suggestions._health_providers = {}
        suggestions._network_key = function() return "n" end
        -- The passive path must never probe: any call is a failure.
        inv.probe_tier = function() error("passive path probed") end
        inv.probe_all = function() error("passive path probed") end
        inv.declarations = function() error("passive path declared") end
    end)
    after_each(function()
        suggestions._providers, suggestions._health_providers = saved.providers, saved.health
        inv.environment_key, inv.probe_tier, inv.probe_all = saved.key, saved.probe_tier, saved.probe_all
        inv.declarations, suggestions._network_key = saved.declarations, saved.network_key
    end)

    local TIER = {
        results = { { id = "exe:tool", label = "tool", status = "missing", category = "build tools", hint = "get tool" } },
        declared = { { id = "exe:tool", category = "build tools" } },
        key = "ENV1", computed_at = 1,
    }

    it("no inventory tier → contributes nothing", function()
        inv.environment_key = function() return "ENV1" end
        local ws = fake_ws(mem_io())
        assert.equals(0, suggestions.count_actionable(ws))
    end)

    it("matching environment key → missing required items count, without probing", function()
        inv.environment_key = function() return "ENV1" end
        local io_dep = mem_io()
        health_cache.write(io_dep, "/root", { inventory_tier = TIER })
        local ws = fake_ws(io_dep)
        local out = suggestions.collect(ws)
        assert.equals(1, #out)
        assert.equals("tool not found — needed by App", out[1].title)
        assert.equals(1, suggestions.count_actionable(ws))
    end)

    it("a mismatched environment key → the tier is not trusted, nothing counts", function()
        inv.environment_key = function() return "ENV2" end
        local io_dep = mem_io()
        health_cache.write(io_dep, "/root", { inventory_tier = TIER })
        assert.equals(0, suggestions.count_actionable(fake_ws(io_dep)))
    end)

    it("collect_health stores a fresh tier and reports it", function()
        inv.environment_key = function() return "ENV1" end
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local out = suggestions.collect_health(ws, { inventory = TIER })
        assert.equals(1, #out)
        local data = health_cache.read(io_dep, "/root")
        assert.equals("ENV1", data.inventory_tier.key)
        assert.equals("exe:tool", data.inventory_tier.results[1].id)
        -- …and the later passive count reuses it.
        assert.equals(1, suggestions.count_actionable(ws))
    end)

    it("health_cache drops a malformed inventory tier", function()
        local io_dep = mem_io()
        io_dep.store[health_cache.path("/root")] = vim.json.encode({
            _meta = { version = health_cache.SCHEMA_VERSION }, inventory_tier = { results = "nope" } })
        assert.is_nil(health_cache.read(io_dep, "/root").inventory_tier)
    end)
end)

-- ---------------------------------------------------------------------------
-- Environment key
-- ---------------------------------------------------------------------------
describe("inventory environment key", function()
    local saved
    before_each(function() saved = inv._contributors end)
    after_each(function() inv._contributors = saved end)

    it("changes with the contributors and the pinned SDKs, not otherwise", function()
        inv._contributors = { { kind = "module", id = "cmake", api = 1 } }
        local k1 = inv.environment_key(nil)
        assert.equals(k1, inv.environment_key(nil))
        inv._contributors = { { kind = "module", id = "cmake", api = 2 } }
        assert.are_not.equal(k1, inv.environment_key(nil))
        local ws = { _profiles = { { sdk = function() return { key = "s1", _path = "/x" } end } } }
        inv._contributors = { { kind = "module", id = "cmake", api = 1 } }
        assert.are_not.equal(k1, inv.environment_key(ws))
    end)
end)

-- ---------------------------------------------------------------------------
-- Plugin registry (rejected plugins)
-- ---------------------------------------------------------------------------
describe("inventory plugin registry", function()
    it("modules.rejected() reports an interface-version mismatch with the reason", function()
        local modules = require("loomworks.modules")
        local orig_notify = vim.notify
        vim.notify = function() end
        package.preload["loomworks.modules.invtest_old"] = function()
            return { id = "invtest_old", api_version = 999 }
        end
        assert.is_nil(modules.get("invtest_old"))
        vim.notify = orig_notify
        package.preload["loomworks.modules.invtest_old"] = nil
        local reason = modules.rejected()["invtest_old"]
        assert.is_truthy(reason and reason:find("api_version=999", 1, true))
    end)

    it("lists loaded plugins and a rejected one as missing with the reason", function()
        local saved = inv._contributors
        inv._contributors = {
            { kind = "module", id = "cmake", api = 1, impl = {} },
            { kind = "module", id = "old", rejected = "api mismatch" },
            { kind = "integration", id = "clangd", impl = { health_inventory = function() return {} end } },
        }
        local ctx = fake_ctx()
        local by = probe(inv.declarations(ctx), ctx)
        inv._contributors = saved
        assert.equals("found", by["module:cmake"].status)
        assert.equals("api 1", by["module:cmake"].version)
        assert.equals("missing", by["module:old"].status)
        assert.equals("rejected: api mismatch", by["module:old"].detail)
        assert.equals("found", by["integration:clangd"].status)
        assert.equals("plugins", by["module:old"].category)
    end)
end)

