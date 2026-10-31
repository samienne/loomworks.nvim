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

--- @param opts? { projects?: table, sets?: table, cache?: string, profiles?: string[] }
---   profiles: the sets made into profiles (default: every set)
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
    end)
end)
