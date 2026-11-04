--- Spec §1.7 "Resolution granularity is the ConfigUnit": with a multi-config
--- cmake generator (Ninja Multi-Config, Visual Studio) Debug and Release share
--- ONE build directory, yet they are DISTINCT ConfigUnits, each with its own
--- configuration, state and artifacts.
---
--- The build-dir path comes from the real cmake module's resolve_build_dir,
--- which returns one directory per kit for a multi-config generator.

local Core = require("loomworks.core")
local h = require("tests.helpers")

local KIT = { id = "ninja-mc", generator = "Ninja Multi-Config" }

local ROOT = "/root"
local TREE = "build/App/ninja-mc"
local TREE_ABS = ROOT .. "/.nvim/" .. TREE

--- @param opts? { cache?: table, app?: table, sets?: table, profiles?: table, deps?: table }
local function make_core(opts)
    opts = opts or {}
    local real_modules = require("loomworks.modules")
    local fake_cmake = setmetatable({
        detect_tools = function() return { { tool_data = KIT } } end,
        info = function()
            return { configurations = {
                Debug = { variant = "Debug" },
                Release = { variant = "Release" },
            } }
        end,
    }, { __index = real_modules.get("cmake") })
    local sets = { debug = { App = "Debug" }, release = { App = "Release" } }
    local profiles = {
        debug = { configuration_set = "debug",
            tools = { cmake = { key = KIT.id, data = KIT } } },
        release = { configuration_set = "release",
            tools = { cmake = { key = KIT.id, data = KIT } } },
    }
    for k, v in pairs(opts.sets or {}) do sets[k] = v end
    for k, v in pairs(opts.profiles or {}) do profiles[k] = v end
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { cmake = opts.app or {} } },
            configuration_sets = sets,
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = profiles }),
    }
    if opts.cache then files["loomworks.cache.json"] = vim.json.encode(opts.cache) end
    local saves = {}
    local deps_opts = {
        modules = { get = function(id) if id == "cmake" then return fake_cmake end end },
        cache = { save = function(_, data) saves[#saves + 1] = vim.deepcopy(data); return true end },
    }
    for k, v in pairs(opts.deps or {}) do deps_opts[k] = v end
    local deps = h.make_test_deps(files, deps_opts)
    local core = Core.new(deps)
    core:setup({ root = ROOT })
    local loaded_saves = #saves
    core._workspace._tools_by_type = { cmake = { { tool_key = KIT.id, tool_data = KIT, tool_label = KIT.id } } }
    core:remerge()
    return core, core:get_workspace(), saves, loaded_saves
end

local function unit_of(ws, profile_key)
    local profile = h.find_profile(ws._profiles, profile_key .. ":" .. KIT.id)
    if not profile then
        local keys = {}
        for _, p in pairs(ws._profiles) do keys[#keys + 1] = p.key end
        error("profile " .. profile_key .. " not in " .. vim.inspect(keys))
    end
    local pp = profile:project("App")
    assert.is_not_nil(pp, "profile project App in " .. profile_key)
    return pp._config_unit
end

describe("multi-config cmake: shared build dir, distinct ConfigUnits (spec §1.7)", function()
    it("Debug and Release share one build directory", function()
        local _, ws = make_core()
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        assert.is_not_nil(d)
        assert.is_not_nil(r)
        assert.equals(d:build_dir(), r:build_dir())
    end)

    it("resolves Debug and Release to distinct ConfigUnits with their own configuration", function()
        local _, ws = make_core()
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        assert.equals("Debug", d:configuration().name)
        assert.equals("Release", r:configuration().name)
        assert.are_not.equal(d, r)
    end)

    it("building Debug does not mark Release built", function()
        local core, ws = make_core()
        local d = unit_of(ws, "debug")
        local debug_profile = h.find_profile(ws._profiles, "debug:" .. KIT.id)
        core:record_task_result({ unit = d, action = "configure", success = true,
            profile = debug_profile, build_dir = d:build_dir() })
        core:record_task_result({ unit = d, action = "build", success = true,
            profile = debug_profile })
        assert.equals("built", d:state())
        core:remerge()
        local r = unit_of(ws, "release")
        assert.are_not.equal("built", r:state())
        assert.equals("built", unit_of(ws, "debug"):state())
    end)
    it("keys each unit by the tree, '#', and its config_key (spec §1.7 Unit identity)", function()
        local _, ws = make_core()
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        assert.equals(TREE .. "#Debug:ninja-mc", d.id)
        assert.equals(TREE .. "#Release:ninja-mc", r.id)
        assert.equals(TREE_ABS, d:build_dir())
    end)

    it("cmake reports shared only for its own multi-config layout, never a preset binaryDir", function()
        local cmake = require("loomworks.modules").get("cmake")
        local dir, shared = cmake.resolve_build_dir("App", "Debug", {}, ROOT, KIT)
        assert.equals(TREE_ABS, dir)
        assert.is_true(shared)
        local _, preset_shared = cmake.resolve_build_dir("App", "Debug",
            { binary_dir = "${sourceDir}/out/${presetName}" }, ROOT, KIT)
        assert.is_falsy(preset_shared)
        local _, single_shared = cmake.resolve_build_dir("App", "Debug", {}, ROOT,
            { id = "ninja", generator = "Ninja" })
        assert.is_falsy(single_shared)
    end)

    it("a version 9 cache gives each configuration of the tree its own state", function()
        local _, ws = make_core({ cache = {
            _meta = { version = 9 },
            build_dirs = {
                [TREE .. "#Debug:ninja-mc"] = { project_key = "App", config_key = "Debug:ninja-mc",
                    type = "cmake", variant = "Debug", state = "configured", build_dir = TREE_ABS,
                    tool_key = KIT.id, tool_data = KIT },
                [TREE .. "#Release:ninja-mc"] = { project_key = "App", config_key = "Release:ninja-mc",
                    type = "cmake", variant = "Release", state = "built", build_dir = TREE_ABS,
                    last_built = "2026-10-01T00:00:00Z", tool_key = KIT.id, tool_data = KIT },
            },
        } })
        assert.equals("configured", unit_of(ws, "debug"):state())
        assert.equals("built", unit_of(ws, "release"):state())
    end)
end)

describe("multi-config cmake: version 8 cache migration (three-file-model §2.3)", function()
    local function v8_cache()
        return {
            _meta = { version = 8 },
            build_dirs = {
                -- v8: one entry for the whole tree, holding whichever
                -- configuration resolved first.
                [TREE] = { project_key = "App", config_key = "Debug:ninja-mc", type = "cmake",
                    variant = "Debug", state = "built", last_configured = "2026-10-01T00:00:00Z",
                    last_built = "2026-10-02T00:00:00Z", build_dir = TREE_ABS,
                    tool_key = KIT.id, tool_data = KIT },
                ["build/Other/Debug"] = { project_key = "Other", config_key = "Debug",
                    type = "cmake", variant = "Debug", state = "built",
                    build_dir = ROOT .. "/.nvim/build/Other/Debug", overwritten_by = TREE },
            },
            deploy_state = {
                ["/root/out/app.exe"] = { source_build_dir = TREE, source_rel_path = "Debug/app.exe",
                    source_mtime = 1 },
            },
        }
    end

    it("moves the matched entry to the unit's id, downgrading its build result", function()
        local _, ws = make_core({ cache = v8_cache() })
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        assert.equals(TREE .. "#Debug:ninja-mc", d.id)
        assert.equals("configured", d:state())
        assert.is_nil(d.last_built)
        assert.equals("2026-10-01T00:00:00Z", d.last_configured)
        -- The tree's other configuration gets no entry: unconfigured.
        assert.equals("unconfigured", r:state())
        assert.is_nil(ws:find_build_dir(TREE))
    end)

    it("rewrites overwritten_by and deploy source_build_dir naming the old key; orphans stay", function()
        local _, ws = make_core({ cache = v8_cache() })
        local serialized = ws:_serialize_cache()
        assert.is_nil(serialized.build_dirs[TREE])
        assert.is_not_nil(serialized.build_dirs[TREE .. "#Debug:ninja-mc"])
        local other = serialized.build_dirs["build/Other/Debug"]
        assert.is_not_nil(other, "unmatched entry keeps its key (orphaned)")
        assert.equals(TREE .. "#Debug:ninja-mc", other.overwritten_by)
        assert.equals(TREE .. "#Debug:ninja-mc",
            ws._deploy_records["/root/out/app.exe"].source_build_dir)
    end)

    it("never writes the cache while loading; the next save writes version 9", function()
        local _, ws, saves, loaded_saves = make_core({ cache = v8_cache() })
        assert.equals(0, loaded_saves)
        ws:_save_cache()
        local last = saves[#saves]
        assert.is_not_nil(last)
        -- cache.save stamps CURRENT_VERSION (stubbed here)
        assert.equals(9, require("loomworks.cache").CURRENT_VERSION)
        assert.is_not_nil(last.build_dirs[TREE .. "#Debug:ninja-mc"])
        assert.is_nil(last.build_dirs[TREE])
    end)
end)

describe("multi-config cmake: renames and deletion", function()
    local function with_dev()
        return make_core({
            app = { configurations = { Dev = { inherits = "Debug" } } },
            sets = { dev = { App = "Dev" } },
            profiles = { dev = { configuration_set = "dev",
                tools = { cmake = { key = KIT.id, data = KIT } } } },
        })
    end

    it("a configuration rename moves the unit to <dir>#<new config_key> with its state and references", function()
        local core, ws = with_dev()
        local dev = unit_of(ws, "dev")
        local old_id = TREE .. "#Dev:ninja-mc"
        assert.equals(old_id, dev.id)
        local dev_profile = h.find_profile(ws._profiles, "dev:" .. KIT.id)
        core:record_task_result({ unit = dev, action = "configure", success = true,
            profile = dev_profile, build_dir = dev:build_dir() })
        core:record_task_result({ unit = dev, action = "build", success = true, profile = dev_profile })
        local d = unit_of(ws, "debug")
        d._overwritten_by = old_id
        ws._deploy_records["/root/out/dev.exe"] = { source_build_dir = old_id,
            source_rel_path = "Dev/app.exe", source_mtime = 1 }

        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_true((app:rename_configuration("Dev", "Dev2", { inherits = "Debug" })))

        assert.equals(TREE .. "#Dev2:ninja-mc", dev.id)
        assert.equals("built", dev:state())
        assert.equals(TREE_ABS, dev:build_dir())
        assert.equals(TREE .. "#Dev2:ninja-mc", d._overwritten_by)
        assert.equals(TREE .. "#Dev2:ninja-mc", ws._deploy_records["/root/out/dev.exe"].source_build_dir)
        local serialized = ws:_serialize_cache()
        assert.is_nil(serialized.build_dirs[old_id])
        assert.equals("Dev2:ninja-mc", serialized.build_dirs[TREE .. "#Dev2:ninja-mc"].config_key)
    end)

    it("a project rename keeps the units' ids", function()
        local _, ws = make_core()
        local d = unit_of(ws, "debug")
        local id = d.id
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_true((ws:rename_project(app, "App2")))
        assert.equals(id, d.id)
    end)

    it("deleting one configuration's unit keeps the tree while another unit references it", function()
        local removed, notes = {}, {}
        local core, ws = make_core({ deps = { notify = function(msg) notes[#notes + 1] = msg end, io = {
            rm_rf_async = function(dir, cb) removed[#removed + 1] = dir; cb(true, nil) end,
            rm_rf = function(dir) removed[#removed + 1] = dir; return true end,
        } } })
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        for _, pair in ipairs({ { d, "debug" }, { r, "release" } }) do
            local prof = h.find_profile(ws._profiles, pair[2] .. ":" .. KIT.id)
            core:record_task_result({ unit = pair[1], action = "configure", success = true,
                profile = prof, build_dir = pair[1]:build_dir() })
            core:record_task_result({ unit = pair[1], action = "build", success = true, profile = prof })
        end
        assert.equals(2, #ws:get_build_dir_refs(TREE_ABS))
        local done = false
        d:delete(function() done = true end)
        vim.wait(1000, function() return done end)
        for _, dir in ipairs(removed) do
            assert.are_not.equal(TREE_ABS, dir, "shared tree removed while Release references it")
        end
        assert.equals("built", r:state())
        local kept = false
        for _, m in ipairs(notes) do
            if tostring(m):find("skipped deleting", 1, true) then kept = true end
        end
        assert.is_true(kept, "deletion reached the shared-dir refs check")
    end)
end)

--- Build both units (configure + build) through record_task_result.
local function build_both(core, ws)
    local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
    for _, pair in ipairs({ { d, "debug" }, { r, "release" } }) do
        local prof = h.find_profile(ws._profiles, pair[2] .. ":" .. KIT.id)
        core:record_task_result({ unit = pair[1], action = "configure", success = true,
            profile = prof, build_dir = pair[1]:build_dir() })
        core:record_task_result({ unit = pair[1], action = "build", success = true, profile = prof })
    end
    return d, r
end

--- An io stub whose rm_rf_async records the dir, runs `on_rm` (to inspect the
--- state at removal time) and reports success unless `ok` is false.
local function rm_io(removed, on_rm, ok)
    return {
        rm_rf_async = function(dir, cb)
            removed[#removed + 1] = dir
            if on_rm then on_rm(dir) end
            if ok == false then cb(false, "boom") else cb(true, nil) end
        end,
        rm_rf = function(dir) removed[#removed + 1] = dir; return ok ~= false end,
    }
end

local function v9_entry(cfg, state)
    return { project_key = "App", config_key = cfg .. ":ninja-mc", type = "cmake",
        variant = cfg, state = state, build_dir = TREE_ABS, tool_key = KIT.id, tool_data = KIT }
end

describe("multi-config cmake: deleting a shared tree (spec §4.6, §5.7 crash safety)", function()
    local function delete_items(ws, units)
        local items = {}
        for _, u in ipairs(units) do
            items[#items + 1] = { unit = u, build_dir = u:build_dir(), disposition = "clean" }
        end
        local done, result = false, nil
        ws:execute_deletion({ items = items }):next(function(ok) result = ok; done = true end,
            function() done = true end)
        vim.wait(1000, function() return done end)
        return result
    end

    it("deleting both units removes the tree once, marking both unknown first and dropping both after", function()
        local removed, at_rm = {}, nil
        local core, ws, saves
        core, ws, saves = make_core({ deps = { io = rm_io(removed, function()
            local last = saves[#saves].build_dirs
            at_rm = { last[TREE .. "#Debug:ninja-mc"].state, last[TREE .. "#Release:ninja-mc"].state }
        end) } })
        local d, r = build_both(core, ws)
        assert.is_true(delete_items(ws, { d, r }))
        assert.same({ TREE_ABS }, removed)
        assert.same({ "unknown", "unknown" }, at_rm)
        assert.equals("unconfigured", d:state())
        assert.equals("unconfigured", r:state())
    end)

    it("a failed removal keeps both siblings unknown", function()
        local removed = {}
        local core, ws = make_core({ deps = { io = rm_io(removed, nil, false),
            notify = function() end } })
        local d, r = build_both(core, ws)
        assert.is_false(delete_items(ws, { d, r }))
        local s = ws:_serialize_cache().build_dirs
        assert.equals("unknown", s[TREE .. "#Debug:ninja-mc"].state)
        assert.equals("unknown", s[TREE .. "#Release:ninja-mc"].state)
    end)

    local function orphan_cache()
        return {
            _meta = { version = 9 },
            build_dirs = {
                [TREE .. "#Debug:ninja-mc"] = v9_entry("Debug", "built"),
                -- A configuration no profile uses any more: an orphan in the same tree.
                [TREE .. "#Old:ninja-mc"] = v9_entry("Old", "built"),
            },
        }
    end

    --- Only Debug is live (both profiles map App to Debug).
    local function debug_only()
        return { cache = orphan_cache(), sets = { release = { App = "Debug" } } }
    end

    it("an orphaned sibling is marked unknown before the tree is removed and dropped after", function()
        local removed, at_rm = {}, nil
        local ws, saves
        local opts = debug_only()
        opts.deps = { io = rm_io(removed, function()
            local e = saves[#saves].build_dirs[TREE .. "#Old:ninja-mc"]
            at_rm = e and e.state
        end) }
        _, ws, saves = make_core(opts)
        assert.is_not_nil(ws:find_build_dir(TREE .. "#Old:ninja-mc"), "orphan loaded")
        local d = unit_of(ws, "debug")
        assert.equals(d, unit_of(ws, "release"))
        assert.is_true(delete_items(ws, { d }))
        assert.same({ TREE_ABS }, removed)
        assert.equals("unknown", at_rm)
        assert.is_nil(ws:find_build_dir(TREE .. "#Old:ninja-mc"))
        assert.is_nil(ws:_serialize_cache().build_dirs[TREE .. "#Old:ninja-mc"])
    end)

    it("an orphaned sibling stays unknown when the removal fails", function()
        local removed = {}
        local opts = debug_only()
        opts.deps = { io = rm_io(removed, nil, false), notify = function() end }
        local _, ws = make_core(opts)
        assert.is_false(delete_items(ws, { unit_of(ws, "debug") }))
        assert.same({ TREE_ABS }, removed)
        assert.equals("unknown", ws:_serialize_cache().build_dirs[TREE .. "#Old:ninja-mc"].state)
    end)

    it("an orphaned sibling keeps its state when the cache save before the removal fails", function()
        local removed, fail = {}, false
        local opts = debug_only()
        opts.deps = { io = rm_io(removed), notify = function() end,
            cache = { save = function() return not fail end } }
        local _, ws = make_core(opts)
        local d = unit_of(ws, "debug")
        assert.equals("built", ws:find_build_dir(TREE .. "#Old:ninja-mc").state)
        fail = true
        assert.is_false(delete_items(ws, { d }))
        assert.same({}, removed, "nothing is removed when the unknown marks never reached disk")
        assert.equals("built", ws:find_build_dir(TREE .. "#Old:ninja-mc").state)
        assert.equals("built", ws:_serialize_cache().build_dirs[TREE .. "#Old:ninja-mc"].state)
        assert.equals("built", d.state_value)
    end)

    it("a kept tree (still referenced) leaves its orphaned sibling untouched", function()
        local removed = {}
        local core, ws = make_core({ cache = orphan_cache(), deps = { io = rm_io(removed),
            notify = function() end } })
        local d = build_both(core, ws)
        assert.is_true(delete_items(ws, { d }))
        assert.same({}, removed)
        assert.equals("built", ws:find_build_dir(TREE .. "#Old:ninja-mc").state)
    end)
end)

describe("multi-config cmake: cache input hardening (three-file-model §2.3)", function()
    it("a crafted top-level _v8_moved in a version 9 file is ignored", function()
        local cache = require("loomworks.cache")
        local data = cache.parse(vim.json.encode({ _meta = { version = 9 }, _v8_moved = { x = true },
            build_dirs = { [TREE .. "#Debug:ninja-mc"] = v9_entry("Debug", "built") } }))
        assert.is_nil(data._v8_moved)
        local _, ws = make_core({ cache = { _meta = { version = 9 }, _v8_moved = { x = true },
            build_dirs = { [TREE .. "#Debug:ninja-mc"] = v9_entry("Debug", "built") } } })
        local d = unit_of(ws, "debug")
        assert.equals(TREE .. "#Debug:ninja-mc", d.id)
        assert.equals("built", d:state())
    end)

    it("a version 8 file still migrates", function()
        local data = require("loomworks.cache").parse(
            vim.json.encode({ _meta = { version = 8 }, build_dirs = {} }))
        assert.is_not_nil(data._v8_moved)
    end)

    it("never derives a directory from a shared id (entry without build_dir)", function()
        local entry = v9_entry("Debug", "built")
        entry.build_dir = nil
        local orphan = v9_entry("Old", "built")
        orphan.build_dir = nil
        local _, ws = make_core({ cache = { _meta = { version = 9 }, build_dirs = {
            [TREE .. "#Debug:ninja-mc"] = entry, [TREE .. "#Old:ninja-mc"] = orphan } } })
        assert.equals(TREE_ABS, unit_of(ws, "debug"):build_dir())
        local bd = ws:find_build_dir(TREE .. "#Old:ninja-mc")
        assert.is_true(bd == nil or bd.path == nil or not bd.path:find("#", 1, true),
            "orphan path derived from its id: " .. tostring(bd and bd.path))
    end)

    it("record_task_result's fallback builds one id with or without a build_dir", function()
        for _, with_dir in ipairs({ false, true }) do
            local core, ws = make_core()
            core:record_task_result({ project_key = "App", configuration_key = "Debug:ninja-mc",
                tool = { key = KIT.id, data = KIT }, action = "configure", success = true,
                build_dir = with_dir and TREE_ABS or nil })
            local ids = {}
            for _, u in pairs(ws._config_units) do ids[u.id] = true end
            assert.is_true(ids[TREE .. "#Debug:ninja-mc"] or false,
                "with_dir=" .. tostring(with_dir) .. " ids " .. vim.inspect(vim.tbl_keys(ids)))
            for id in pairs(ids) do
                assert.is_nil(id:find("ninja-mc:ninja-mc", 1, true), id)
            end
        end
    end)

    it("record_task_result's fallback without a configuration_key records nothing in a shared tree", function()
        local core, ws = make_core()
        local before = #ws._config_units
        assert.has_no.errors(function()
            core:record_task_result({ project_key = "App", variant = "Debug",
                tool = { key = KIT.id, data = KIT }, action = "configure", success = true,
                build_dir = TREE_ABS })
        end)
        assert.equals(before, #ws._config_units)
    end)
end)

describe("multi-config cmake: siblings share directory-level state", function()
    it("a vanished tree resets every sibling (spec §3.1 rule 7)", function()
        local _, ws = make_core({ cache = { _meta = { version = 9 }, build_dirs = {
            [TREE .. "#Debug:ninja-mc"] = v9_entry("Debug", "built"),
            [TREE .. "#Release:ninja-mc"] = v9_entry("Release", "configured"),
        } }, deps = { dir_exists = function(p) return p ~= TREE_ABS end } })
        assert.equals("unconfigured", unit_of(ws, "debug"):state())
        assert.equals("unconfigured", unit_of(ws, "release"):state())
    end)

    it("an exclusive lock on Debug's tree queues a Release build (spec §16.6)", function()
        local _, ws = make_core()
        local d, r = unit_of(ws, "debug"), unit_of(ws, "release")
        local ran = {}
        assert.is_true(ws:acquire_build_dir_lock(d:build_dir(), "exclusive", function()
            ran[#ran + 1] = "configure Debug" end))
        assert.is_false(ws:acquire_build_dir_lock(r:build_dir(), "shared", function()
            ran[#ran + 1] = "build Release" end))
        assert.same({ "configure Debug" }, ran)
        ws:release_build_dir_lock(d:build_dir(), "exclusive")
        assert.same({ "configure Debug", "build Release" }, ran)
    end)
end)

describe("multi-config cmake: rename onto an orphaned id (spec §4.8)", function()
    it("drops the orphan's deploy records and overwritten_by instead of moving them to the renamed unit", function()
        local core, ws = make_core({
            app = { configurations = { Dev = { inherits = "Debug" } } },
            sets = { dev = { App = "Dev" } },
            profiles = { dev = { configuration_set = "dev",
                tools = { cmake = { key = KIT.id, data = KIT } } } },
            cache = { _meta = { version = 9 }, build_dirs = {
                [TREE .. "#Dev2:ninja-mc"] = v9_entry("Dev2", "built"),
                ["build/Other/Debug"] = { project_key = "Other", config_key = "Debug",
                    type = "cmake", variant = "Debug", state = "built",
                    build_dir = ROOT .. "/.nvim/build/Other/Debug",
                    overwritten_by = TREE .. "#Dev2:ninja-mc" },
            }, deploy_state = {
                ["/root/out/old.exe"] = { source_build_dir = TREE .. "#Dev2:ninja-mc",
                    source_rel_path = "Dev2/app.exe", source_mtime = 1 },
            } },
        })
        local dev = unit_of(ws, "dev")
        local dev_profile = h.find_profile(ws._profiles, "dev:" .. KIT.id)
        core:record_task_result({ unit = dev, action = "configure", success = true,
            profile = dev_profile, build_dir = dev:build_dir() })
        local app = h.find_project_in(ws:get_projects(), "App")
        assert.is_true((app:rename_configuration("Dev", "Dev2", { inherits = "Debug" })))
        assert.equals(TREE .. "#Dev2:ninja-mc", dev.id)
        assert.equals("configured", dev:state())
        assert.is_nil(ws._deploy_records["/root/out/old.exe"])
        assert.is_nil(ws:find_build_dir("build/Other/Debug").overwritten_by)
    end)
end)
