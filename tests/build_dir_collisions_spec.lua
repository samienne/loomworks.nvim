--- Core §1.7 "One build directory per configuration" / invariant 22: two
--- (project, configuration) pairs that resolve to one build directory outside
--- a module's shared tree collide. The owner keeps the directory; every other
--- configuration is refused (no ConfigUnit, an invalid ProfileProject, a load
--- error), and a command that would create a collision is refused.

local Core = require("loomworks.core")
local h = require("tests.helpers")

local ROOT = "/root"

local shell = require("loomworks.modules").get("shell")

--- The shell module, reporting a project's directory as a shared tree when
--- the test project says so (`shared`); shell itself never does.
local function fake_module(shared_projects)
    return setmetatable({
        resolve_build_dir = function(pk, ...)
            return shell.resolve_build_dir(pk, ...), shared_projects[pk] == true
        end,
    }, { __index = shell })
end

--- A shell project: configurations `names` (default Debug, Release) built
--- into `template` (default `${workspace_root}/out`), a configuration's own
--- directory `dirs.<name>` (relative to the root) overriding it.
local function shell_project(p)
    local cfgs = {}
    for _, n in ipairs(p.names or { "Debug", "Release" }) do
        cfgs[n] = { variant = n,
            build_dir = p.dirs and p.dirs[n] and ("${workspace_root}/" .. p.dirs[n]) or nil }
    end
    return { shell = { build_dir = p.template or "${workspace_root}/out", configure_cmd = { "true" },
        build_cmd = { "true" }, configurations = cfgs } }
end

--- @param opts? { projects?: table, sets?: table, cache?: string, profiles?: string[], normalize?: function }
---   profiles: the sets made into profiles (default: every set)
---   normalize: the path normalization (default: the test deps')
local function make_core(opts)
    opts = opts or {}
    local projects, shared = {}, {}
    for k, p in pairs(opts.projects or { App = {} }) do
        projects[k] = shell_project(p)
        shared[k] = p.shared
    end
    local mod = fake_module(shared)
    local sets = opts.sets or { debug = { App = "Debug" }, release = { App = "Release" } }
    local profiles = {}
    for _, name in ipairs(opts.profiles or vim.tbl_keys(sets)) do profiles[name] = { configuration_set = name } end
    local files = {
        ["loomworks.json"] = h.make_config_json({ projects = projects, configuration_sets = sets }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = profiles }),
    }
    if opts.cache then files["loomworks.cache.json"] = opts.cache end
    local user_saves = {}
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) if id == "shell" then return mod end end },
        user = { save = function(_, data) user_saves[#user_saves + 1] = vim.deepcopy(data); return true end },
        normalize = opts.normalize,
    })
    local core = Core.new(deps)
    -- The load's notifications (loomworks.notify) go to the process core.
    require("loomworks")._core = function() return core end
    core:setup({ root = ROOT })
    return core, core:get_workspace(), user_saves
end

local function cs_of(ws, name)
    for _, cs in pairs(ws._config_sets) do
        if cs.name == name then return cs end
    end
end

local function pp_of(ws, set_name, project_key)
    for _, p in pairs(ws._profiles) do
        if p._configuration_set_name == set_name then return p:project(project_key or "App") end
    end
    error("no profile for set " .. set_name)
end

local function msg(dir, pk, cfg, opk, ocfg)
    return "Build directory " .. dir .. " of " .. pk .. "/" .. cfg .. " is already used by "
        .. opk .. "/" .. ocfg .. "; " .. pk .. "/" .. cfg
        .. " cannot be built until its build directory resolves elsewhere."
end

local function load_errors(ws)
    local out = {}
    for _, d in ipairs(ws:load_diagnostics()) do
        if d.severity == "error" then out[#out + 1] = d.message end
    end
    return out
end

describe("build directory collisions (core §1.7, invariant 22)", function()
    local lw = require("loomworks")
    local orig_core = lw._core
    after_each(function() lw._core = orig_core end)

    it("two configurations of one project on one directory: the first by name keeps it", function()
        local _, ws = make_core()
        local d, r = pp_of(ws, "debug"), pp_of(ws, "release")
        assert.is_not_nil(d._config_unit)
        assert.equals("Debug", d._config_unit:configuration().name)
        assert.is_nil(r._config_unit)
        local m = msg("out", "App", "Release", "App", "Debug")
        assert.equals(m, r:build_dir_error())
        assert.equals(m, r:invalid_reason())
        assert.is_nil(d:build_dir_error())
    end)

    it("raises one load error per refused configuration, with the exact message", function()
        local _, ws = make_core({ sets = { debug = { App = "Debug" }, release = { App = "Release" },
            release2 = { App = "Release" } } })
        assert.same({ msg("out", "App", "Release", "App", "Debug") }, load_errors(ws))
    end)

    it("the configuration a cache entry for the directory names keeps it", function()
        local _, ws = make_core({ cache = h.make_cache_json({ build_dirs = {
            ["/root/out"] = { project_key = "App", config_key = "Release", variant = "Release",
                type = "shell", build_dir = "/root/out", state = "built" },
        } }) })
        local d, r = pp_of(ws, "debug"), pp_of(ws, "release")
        assert.is_not_nil(r._config_unit)
        assert.equals("built", r._config_unit:state())
        assert.is_nil(d._config_unit)
        assert.equals(msg("out", "App", "Debug", "App", "Release"), d:build_dir_error())
    end)

    it("a refused configuration never adopts the owner's entry", function()
        local _, ws = make_core({ cache = h.make_cache_json({ build_dirs = {
            ["/root/out"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                type = "shell", build_dir = "/root/out", state = "built" },
        } }) })
        assert.equals("built", pp_of(ws, "debug")._config_unit:state())
        assert.is_nil(pp_of(ws, "release")._config_unit)
        local n = 0
        for _, u in pairs(ws._config_units) do
            if u._project and u._project.key == "App" then n = n + 1 end
        end
        assert.equals(1, n)
    end)

    it("an entry naming a configuration that no longer exists names no owner", function()
        local _, ws = make_core({ cache = h.make_cache_json({ build_dirs = {
            ["/root/out"] = { project_key = "Gone", config_key = "Release", variant = "Release",
                type = "shell", build_dir = "/root/out", state = "built" },
        } }) })
        assert.is_not_nil(pp_of(ws, "debug")._config_unit)
        assert.is_nil(pp_of(ws, "release")._config_unit)
    end)

    it("configurations of different projects collide; the first project key keeps it", function()
        local _, ws = make_core({
            projects = { Lib = { names = { "Debug" } }, App = { names = { "Debug" } } },
            sets = { debug = { App = "Debug", Lib = "Debug" } },
        })
        assert.is_not_nil(pp_of(ws, "debug", "App")._config_unit)
        assert.is_nil(pp_of(ws, "debug", "Lib")._config_unit)
        assert.equals(msg("out", "Lib", "Debug", "App", "Debug"), pp_of(ws, "debug", "Lib"):build_dir_error())
    end)

    it("a shared tree of one project and tool does not collide", function()
        local _, ws = make_core({ projects = { App = { shared = true } } })
        assert.is_not_nil(pp_of(ws, "debug")._config_unit)
        assert.is_not_nil(pp_of(ws, "release")._config_unit)
        assert.equals("out#Debug", pp_of(ws, "debug")._config_unit.id:gsub("^/root/", ""))
        assert.same({}, load_errors(ws))
    end)

    it("a shared-tree unit never adopts an entry keyed by the plain directory", function()
        local _, ws = make_core({ projects = { App = { shared = true } },
            cache = h.make_cache_json({ build_dirs = {
                ["/root/out"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                    type = "shell", build_dir = "/root/out", state = "built" },
            } }) })
        local u = pp_of(ws, "debug")._config_unit
        assert.is_not_nil(u)
        assert.equals("/root/out#Debug", u.id)
        assert.are_not.equal("built", u:state())
    end)

    it("distinct directories do not collide", function()
        local _, ws = make_core({ projects = { App = { dirs = { Debug = "d", Release = "r" } } } })
        assert.is_not_nil(pp_of(ws, "release")._config_unit)
        assert.same({}, load_errors(ws))
    end)

    -- The refused configuration is an invalid ProfileProject: a profile
    -- operation runs the profile's valid projects and fails naming it (core
    -- §5.4 "Invalid ProfileProjects"; tests/profile_invalid_pp_spec.lua has
    -- the partial case). Here it is the profile's only project.
    it("a profile whose only configuration is refused runs nothing and fails naming it", function()
        local _, ws = make_core()
        local pp = pp_of(ws, "release")
        local profile = pp._profile
        local want = msg("out", "App", "Release", "App", "Debug")
        assert.equals(want, (pp:invalid_reason()))
        local loomworks = require("loomworks")
        local orig_gw = loomworks.get_workspace
        loomworks.get_workspace = function() return ws end
        local ok, e = pcall(function()
            local steps, err, refused = require("loomworks.build_run").plan(profile)
            assert.is_nil(err)
            assert.same({}, steps or {})
            assert.same({ "App/Release not run: " .. want }, refused)
            local csteps, crefused = require("loomworks.build_run").plan_clean(profile)
            assert.is_nil(csteps)
            assert.same({ "App/Release not run: " .. want }, crefused)
        end)
        loomworks.get_workspace = orig_gw
        assert.is_true(ok, tostring(e))
    end)

    it("the refusal is re-evaluated each load: a distinct directory lifts it", function()
        local core, ws = make_core()
        assert.is_nil(pp_of(ws, "release")._config_unit)
        local app = h.find_project_in(ws._projects, "App")
        assert.is_true((app:save_configuration("Release", { variant = "Release",
            build_dir = "${workspace_root}/rel" })))
        core:remerge()
        assert.is_not_nil(pp_of(ws, "release")._config_unit)
        assert.is_nil(pp_of(ws, "release"):build_dir_error())
    end)

    describe("commands refuse to create a collision, writing nothing", function()
        it("mapping a configuration into a profile", function()
            local _, ws, saves = make_core({ projects = { App = {
                names = { "Debug", "Release", "Other" }, dirs = { Release = "rel" } } } })
            local app = h.find_project_in(ws._projects, "App")
            local rel = cs_of(ws, "release")
            local n = #saves
            local ok, err = rel:update_mapping(app, app:get_configuration("Other"))
            assert.is_false(ok)
            assert.equals(msg("out", "App", "Other", "App", "Debug"), err)
            assert.equals(n, #saves)
            assert.equals("Release", rel.mappings[app].name)
            assert.is_not_nil(pp_of(ws, "release")._config_unit)
            assert.is_nil(pp_of(ws, "release"):build_dir_error())
        end)

        it("editing a build-directory field", function()
            local _, ws, saves = make_core({ projects = { App = { template = "${workspace_root}/out/${variant}" } } })
            local app = h.find_project_in(ws._projects, "App")
            -- Release moves onto Debug's directory.
            local n = #saves
            local ok, err = app:save_type_config_field("build_dir", "${workspace_root}/out")
            assert.is_false(ok)
            assert.equals(msg("out", "App", "Release", "App", "Debug"), err)
            assert.equals("${workspace_root}/out/${variant}", app.type_config.build_dir)
            assert.equals(n, #saves)
            assert.is_not_nil(pp_of(ws, "release")._config_unit)
        end)

        it("renaming a configuration onto an occupied directory", function()
            local _, ws, saves = make_core({ projects = { App = {
                template = "${workspace_root}/out/${variant}", dirs = { Debug = "out/X" } } } })
            local app = h.find_project_in(ws._projects, "App")
            local n = #saves
            assert.equals("/root/out/X", pp_of(ws, "debug")._config_unit:build_dir())
            assert.equals("/root/out/Release", pp_of(ws, "release")._config_unit:build_dir())
            local ok, err = app:rename_configuration("Release", "X", { variant = "Release" })
            -- X resolves to `out/X`, Debug's directory.
            assert.is_false(ok)
            assert.equals(msg("out/X", "App", "X", "App", "Debug"), err)
            assert.equals(n, #saves)
            assert.is_not_nil(app:get_configuration("Release"))
        end)

        it("renaming a project whose key its directory derives from", function()
            -- A's directory is `out/<project key>/<configuration>`; B's is
            -- `out/X/<configuration>`: renamed to X, A would take B's.
            local _, ws, saves = make_core({
                projects = {
                    A = { template = "${workspace_root}/out/${project_path}/${variant}" },
                    B = { template = "${workspace_root}/out/X/${variant}" },
                },
                sets = { debug = { A = "Debug", B = "Debug" } },
            })
            local a = h.find_project_in(ws._projects, "A")
            local n = #saves
            local ok, err = ws:rename_project(a, "X")
            assert.is_false(ok)
            assert.equals(msg("out/X/Debug", "X", "Debug", "B", "Debug"), err)
            assert.equals(n, #saves)
            assert.equals("A", a.key)
            assert.is_not_nil(pp_of(ws, "debug", "A")._config_unit)
            assert.is_nil(pp_of(ws, "debug", "A"):invalid_reason())
        end)

        it("creating a profile of a set mapping an occupied directory", function()
            -- No profile maps Other yet, so nothing claims its directory
            -- (Debug's, `out`); a profile of set `other` would.
            local _, ws, saves = make_core({
                projects = { App = { names = { "Debug", "Other" } } },
                sets = { debug = { App = "Debug" }, other = { App = "Other" } },
                profiles = { "debug" },
            })
            local n, np = #saves, #ws._profiles
            local r = require("loomworks.model_commands").profile_create(ws, cs_of(ws, "other"), nil, false)
            assert.equals("refused", r.outcome)
            assert.equals(msg("out", "App", "Other", "App", "Debug"), r.message)
            assert.equals(n, #saves)
            assert.equals(np, #ws._profiles)
            assert.is_falsy(pp_of(ws, "debug")._profile._removed)
            assert.is_nil(pp_of(ws, "debug"):invalid_reason())
        end)

        --- Set `other` (App=Other) maps Debug's directory `out`; only `debug`
        --- is a profile. Returns ws, saves.
        local function other_ws()
            local _, ws, saves = make_core({
                projects = { App = { names = { "Debug", "Other" } } },
                sets = { debug = { App = "Debug" }, other = { App = "Other" } },
                profiles = { "debug" },
            })
            return ws, saves
        end
        local OTHER = msg("out", "App", "Other", "App", "Debug")

        it("every profile-creating entry point refuses it the same way", function()
            for _, make in ipairs({
                function(_, cs) return cs:ensure_profile(nil) end,
                function(_, cs) return cs:activate(nil) end,
                function(ws, cs) return ws:create_profile(cs, nil, false) end,
                function(ws, cs) return ws:create_profile(cs, nil, true) end,
            }) do
                local ws, saves = other_ws()
                local n, np, nu = #saves, #ws._profiles, #ws._config_units
                local active = ws._active_profile
                local profile, err = make(ws, cs_of(ws, "other"))
                assert.is_nil(profile)
                assert.equals(OTHER, err)
                assert.equals(n, #saves)
                assert.equals(np, #ws._profiles)
                assert.equals(nu, #ws._config_units)
                assert.equals(active, ws._active_profile)
                assert.is_nil(pp_of(ws, "debug"):invalid_reason())
            end
        end)

        it("a stale owner unit is never re-applied to the refused configuration", function()
            local ws = other_ws()
            local u = pp_of(ws, "debug")._config_unit
            local debug_cfg = u._configuration
            -- As after a deletion cleared it.
            u._configuration = nil
            local r = require("loomworks.model_commands").profile_create(ws, cs_of(ws, "other"), nil, false)
            assert.equals("refused", r.outcome)
            assert.is_nil(u._configuration)
            u._configuration = debug_cfg
        end)
    end)

    describe("deleting a profile whose configuration is refused", function()
        local io_mod = require("loomworks.io")
        local real_async, real_sync
        local removed
        before_each(function()
            removed = {}
            real_async, real_sync = io_mod.rm_rf_async, io_mod.rm_rf
            io_mod.rm_rf_async = function(dir, cb)
                removed[#removed + 1] = dir
                if cb then vim.schedule(function() cb(true, nil) end) end
                return require("loomworks.future").resolved(true)
            end
            io_mod.rm_rf = function(dir) removed[#removed + 1] = dir; return true end
        end)
        after_each(function() io_mod.rm_rf_async, io_mod.rm_rf = real_async, real_sync end)

        it("removes no directory and no cache entry", function()
            local _, ws = make_core({ cache = h.make_cache_json({ build_dirs = {
                ["/root/out"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                    type = "shell", build_dir = "/root/out", state = "built" },
            } }) })
            local rel = pp_of(ws, "release")
            assert.is_not_nil(rel:build_dir_error())
            local plan = rel._profile:plan_deletion()
            for _, item in ipairs(plan.items) do
                assert.is_nil(item.unit)
                assert.is_nil(item.build_dir)
            end
            local done = false
            rel._profile:delete(function() done = true end)
            vim.wait(2000, function() return done end, 10)
            assert.same({}, removed)
            local d = pp_of(ws, "debug")._config_unit
            assert.is_not_nil(d)
            assert.equals("built", d:state())
            assert.is_not_nil(ws:_serialize_cache().build_dirs["/root/out"])
        end)
    end)

    -- A configuration's effective directory is its cache entry's build_dir
    -- (its anchor), else the one it resolves to (core §1.7).
    describe("an anchored directory", function()
        local io_mod = require("loomworks.io")
        local real_async, real_sync
        before_each(function()
            real_async, real_sync = io_mod.rm_rf_async, io_mod.rm_rf
            io_mod.rm_rf_async = function(_, cb)
                if cb then vim.schedule(function() cb(true, nil) end) end
                return require("loomworks.future").resolved(true)
            end
            io_mod.rm_rf = function() return true end
        end)
        after_each(function() io_mod.rm_rf_async, io_mod.rm_rf = real_async, real_sync end)

        --- Debug now resolves to `new`; its built entry anchors it at `old`.
        --- Release resolves to `release_dir` (default `old`).
        local function anchored(release_dir, extra)
            local o = { projects = { App = { dirs = { Debug = "new", Release = release_dir or "old" } } },
                cache = h.make_cache_json({ build_dirs = {
                    ["/root/old"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                        type = "shell", build_dir = "/root/old", state = "built" },
                } }) }
            for k, v in pairs(extra or {}) do o[k] = v end
            return o
        end

        it("keeps its anchor after its template changes; a configuration resolving to it is refused", function()
            local _, ws = make_core(anchored())
            local d, r = pp_of(ws, "debug"), pp_of(ws, "release")
            assert.equals("/root/old", d._config_unit:build_dir())
            assert.equals("built", d._config_unit:state())
            assert.is_nil(r._config_unit)
            local m = msg("old", "App", "Release", "App", "Debug")
            assert.equals(m, r:build_dir_error())
            assert.same({ m }, load_errors(ws))
        end)

        it("changing the owner's template again does not release it", function()
            local core, ws = make_core(anchored())
            local app = h.find_project_in(ws._projects, "App")
            assert.is_true((app:save_configuration("Debug", { variant = "Debug",
                build_dir = "${workspace_root}/newer" })))
            core:remerge()
            assert.equals("/root/old", pp_of(ws, "debug")._config_unit:build_dir())
            assert.is_nil(pp_of(ws, "release")._config_unit)
            assert.equals(msg("old", "App", "Release", "App", "Debug"), pp_of(ws, "release"):build_dir_error())
        end)

        it("a command that would make a configuration resolve to it is refused, writing nothing", function()
            local _, ws, saves = make_core(anchored("rel"))
            assert.same({}, load_errors(ws))
            local app = h.find_project_in(ws._projects, "App")
            local n = #saves
            local ok, err = app:save_configuration("Release", { variant = "Release",
                build_dir = "${workspace_root}/old" })
            assert.is_false(ok)
            assert.equals(msg("old", "App", "Release", "App", "Debug"), err)
            assert.equals(n, #saves)
            assert.equals("/root/rel", pp_of(ws, "release")._config_unit:build_dir())
            assert.is_nil(pp_of(ws, "release"):build_dir_error())
        end)

        it("deleting the anchored unit releases it", function()
            local core, ws = make_core(anchored())
            assert.is_nil(pp_of(ws, "release")._config_unit)
            ws:delete_cached_configs({ { unit = pp_of(ws, "debug")._config_unit } })
            core:remerge()
            assert.is_nil(pp_of(ws, "release"):build_dir_error())
            assert.equals("/root/old", pp_of(ws, "release")._config_unit:build_dir())
            assert.equals("/root/new", pp_of(ws, "debug")._config_unit:build_dir())
            assert.is_nil(pp_of(ws, "debug"):build_dir_error())
        end)

        it("an anchor keyed by the directory and its config_key is a shared tree", function()
            local _, ws = make_core({ projects = { App = { shared = true, dirs = { Debug = "new", Release = "old" } } },
                cache = h.make_cache_json({ build_dirs = {
                    ["/root/old#Debug"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                        type = "shell", build_dir = "/root/old", state = "built" },
                } }) })
            assert.equals("/root/old#Debug", pp_of(ws, "debug")._config_unit.id)
            assert.equals("built", pp_of(ws, "debug")._config_unit:state())
            assert.equals("/root/old#Release", pp_of(ws, "release")._config_unit.id)
            assert.same({}, load_errors(ws))
        end)

        it("a different case spelling of the anchor is the same directory (Windows normalization)", function()
            local _, ws = make_core(anchored("OLD", {
                normalize = function(p) return (p:gsub("\\", "/"):lower()) end }))
            assert.is_nil(pp_of(ws, "release")._config_unit)
            assert.equals(msg("old", "App", "Release", "App", "Debug"), pp_of(ws, "release"):build_dir_error())
        end)
    end)

    describe("resolving claims", function()
        local claims_mod = require("loomworks.build_dir_claims")
        local function key_of(p) return (p:lower()) end
        local function claim(pk, cfg, tool, abs, shared)
            return { project_key = pk, config_name = cfg, tool_key = tool,
                config_key = cfg .. (tool and ("-" .. tool) or ""), abs = abs, shared = shared == true }
        end

        it("shows the directory as the owner spells it, whatever the claim order", function()
            local a = claim("A", "Debug", nil, "/r/Out")
            local b = claim("B", "Debug", nil, "/r/OUT")
            local _, r1 = claims_mod.resolve({ a, b }, {}, key_of, { root = "/r" })
            local _, r2 = claims_mod.resolve({ b, a }, {}, key_of, { root = "/r" })
            assert.equals(msg("Out", "B", "Debug", "A", "Debug"), r1[1].message)
            assert.same(r1, r2)
        end)

        it("a configuration with a plain claim besides its shared one is its own claimant", function()
            -- Debug is shared under t1 but also plain under t2 on the same
            -- directory; Release is shared under t1. Not one shared tree.
            local refused, refusals = claims_mod.resolve({
                claim("A", "Debug", "t1", "/r/out", true),
                claim("A", "Debug", "t2", "/r/out", false),
                claim("A", "Release", "t1", "/r/out", true),
            }, {}, key_of, { root = "/r" })
            assert.equals(1, #refusals)
            assert.equals(msg("out", "A", "Release", "A", "Debug"), refusals[1].message)
            assert.is_not_nil(next(refused))
        end)

        it("an anchor keyed by the directory and its config_key is a shared tree", function()
            -- Debug now resolves to `new`, reported plain; its entry anchors
            -- it at `old` as a shared-tree unit.
            local entries = { ["/r/old#Debug-t1"] = { project_key = "A", config_key = "Debug-t1",
                build_dir = "/r/old" } }
            local _, refusals = claims_mod.resolve({
                claim("A", "Debug", "t1", "/r/new", false),
                claim("A", "Release", "t1", "/r/old", true),
            }, entries, key_of, { root = "/r" })
            assert.same({}, refusals)
        end)

        it("an anchor keyed by the plain directory follows the module's report", function()
            local entries = { ["/r/old"] = { project_key = "A", config_key = "Debug-t1",
                build_dir = "/r/old" } }
            local _, refusals = claims_mod.resolve({
                claim("A", "Debug", "t1", "/r/new", false),
                claim("A", "Release", "t1", "/r/old", true),
            }, entries, key_of, { root = "/r" })
            assert.equals(1, #refusals)
            assert.equals(msg("old", "A", "Release", "A", "Debug"), refusals[1].message)
        end)

        it("configurations shared under one tool are one claimant", function()
            local _, refusals = claims_mod.resolve({
                claim("A", "Debug", "t1", "/r/out", true),
                claim("A", "Release", "t1", "/r/out", true),
            }, {}, key_of, { root = "/r" })
            assert.same({}, refusals)
        end)
    end)
end)

-- On disk, through `lw profile create` (spec §1.7): two spellings of one
-- folder are one directory, and the CLI refuses a profile that would collide.
describe("build directory collisions on disk (core §1.7)", function()
    _G.LOOMWORKS_CLI_NO_AUTORUN = true
    local cli = require("loomworks.cli")
    local uv = vim.uv or vim.loop
    local is_win = vim.fn.has("win32") == 1
    local lw = require("loomworks")
    local orig_core = lw._core
    after_each(function() lw._core = orig_core end)

    --- Run `fn`, capturing stderr and an exit code (`die` → os.exit).
    local function run(fn)
        local rw, rs, rx = io.write, io.stderr, os.exit
        local err, code = {}, nil
        io.write = function() end
        io.stderr = { write = function(_, s) err[#err + 1] = s end }
        os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
        local ok, e = pcall(fn)
        io.write, io.stderr, os.exit = rw, rs, rx
        if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
        return code or 0, table.concat(err)
    end

    --- A real workspace root with `<root>/Long Build Directory`.
    local function make_root()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        root = vim.fs.normalize(assert(uv.fs_realpath(root)))
        vim.fn.mkdir(root .. "/App", "p")
        vim.fn.mkdir(root .. "/Long Build Directory", "p")
        return root
    end

    --- App: Debug in `<root>/Long Build Directory`, Release in `rel_dir`
    --- (a template); sets Dev (App=Debug), Rel (App=Release); profile Dev.
    local function setup_ws(root, rel_dir)
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode({ projects = { App = { shell = {
            build_dir = "${workspace_root}/Long Build Directory",
            configure_cmd = { "true" }, build_cmd = { "true" },
            configurations = { Debug = vim.empty_dict(), Release = { build_dir = rel_dir } },
        } } } }))
        f:close()
        local code, err = run(function()
            cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" })
            cli.cmd_cset("create", root, { "configuration-set", "create", "Rel", "App=Release" })
            cli.cmd_profile_create(root, { "profile", "create", "Dev" })
        end)
        assert.equals(0, code, err)
    end

    local function user_json(root)
        local f = io.open(root .. "/.nvim/loomworks.user.json", "rb")
        if not f then return nil end
        local s = f:read("*a"); f:close()
        return s
    end

    local function refused_create(root, rel_dir)
        setup_ws(root, rel_dir)
        local before = user_json(root)
        local code, err = run(function() cli.cmd_profile_create(root, { "profile", "create", "Rel" }) end)
        assert.equals(1, code, err)
        assert.truthy(err:find("of App/Release is already used by App/Debug", 1, true), err)
        assert.equals(before, user_json(root))
    end

    it("lw profile create refuses a profile that would collide, writing nothing", function()
        refused_create(make_root(), "${workspace_root}/Long Build Directory")
    end)

    it("a different case of the directory collides on Windows", function()
        if not is_win then pending("case-insensitive paths are Windows-only"); return end
        refused_create(make_root(), "${workspace_root}/LONG BUILD DIRECTORY")
    end)

    it("the directory's 8.3 short spelling collides", function()
        if not is_win then pending("8.3 short names are Windows-only"); return end
        local root = make_root()
        local dir = root .. "/Long Build Directory"
        local out = vim.fn.system({ "cmd", "/c", "for %I in (\"" .. dir:gsub("/", "\\") .. "\") do @echo %~sI" })
        local short = vim.trim(out or ""):gsub("\\", "/"):match("[^/]+$")
        if vim.v.shell_error ~= 0 or not short or not short:find("~", 1, true) then
            pending("8.3 short names unavailable on this volume"); return
        end
        refused_create(root, "${workspace_root}/" .. short)
    end)
end)
