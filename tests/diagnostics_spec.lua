--- Tests for the structural diagnostics surface.
---
--- Each state-bearing domain object exposes a `:diagnostic()`
--- returning a Diagnostic table or nil. Workspace:diagnostics()
--- aggregates the lot, sorted by (severity, source) for stable
--- output. UI is intentionally not exercised here — the section
--- is a thin renderer.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

local Workspace = workspace.Workspace

--- Fake `harmony`-shaped module: SDK-capable (has kits_from_sdk),
--- so a profile without a tool surfaces as incomplete.
local mock_modules = {
    harmony = {
        has_keyed_tools = false,
        -- kits_from_sdk on the module impl marks it SDK-capable;
        -- a profile without an SDK-derived tool surfaces incomplete.
        kits_from_sdk = function() return {} end,
        info = function()
            local Configuration = require("loomworks.configuration")
            return {
                configurations = Configuration.canonicalize(
                    { default = { prefix = "auto", variant = "default-default" } },
                    nil, "harmony"),
            }
        end,
        default_configurations = function()
            return { default = { prefix = "auto", variant = "default-default" } }
        end,
        map_variant = function() return nil end,
        detect_tools_async = function(callback) callback({}) end,
    },
    typescript = {
        has_keyed_tools = false,
        info = function(_, type_config)
            local Configuration = require("loomworks.configuration")
            return {
                configurations = Configuration.canonicalize(
                    { default = { prefix = "variant", variant = "default" } },
                    type_config and type_config.configurations,
                    "typescript"),
            }
        end,
        default_configurations = function()
            return { default = { prefix = "variant", variant = "default" } }
        end,
        map_variant = function() return nil end,
        detect_tools_async = function(callback) callback({}) end,
    },
}

local function make_ws(config_overrides, user_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local data = workspace.assemble("/root", config_json, user_json, nil)
    assert(data, "assemble failed")

    local mock_core = {
        _deps = {
            merge = merge,
            cache = cache_mod,
            events = { emit = function() end },
            user = { save = function() return true end },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = function(_, cb) cb(true, nil) end,
            },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
            log = require("loomworks.log").test(),
        },
    }

    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    -- Suppress vim.notify for stale-mapping warnings so the test
    -- output is clean — they're a separate concern.
    local orig_notify = vim.notify
    vim.notify = function() end
    package.loaded["loomworks.data_model"] = nil
    require("loomworks.data_model")
    ws:remerge(data.config, data.cache, data.user)
    vim.notify = orig_notify
    return ws, mock_core
end

describe("Workspace:diagnostics", function()
    it("returns empty list when everything is healthy", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
        })
        assert.are.same({}, ws:diagnostics())
    end)

    it("flags incomplete profiles (SDK-capable module without tool)", function()
        local ws = make_ws({
            projects = { App = { harmony = {} } },
            configuration_sets = {
                Debug = { App = "auto:default-default" },
            },
            profiles = {
                ["Debug:noop"] = { configuration_set = "Debug" },
            },
        })
        local diags = ws:diagnostics()
        local found_profile = false
        for _, d in ipairs(diags) do
            if d.source:find("Profile/", 1, true) then
                found_profile = true
                assert.equals("warn", d.severity)
                assert.is_truthy(d.message:find("incomplete", 1, true))
                assert.is_truthy(d.message:find("App", 1, true))
                assert.is_truthy(d.target_fold_key:find("profile:", 1, true))
            end
        end
        assert.is_true(found_profile,
            "expected an incomplete-profile diagnostic")
    end)

    it("flags inherits-only stub (no set covers it — project-side fires)",
       function()
        -- A user config inherits from a base name that doesn't
        -- exist on the project. There's no config_set involved, so
        -- the set-side diagnostic doesn't apply — the project-side
        -- (Configuration:diagnostic) is the only way to surface it.
        -- Test the fallback path that suppression doesn't disable.
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["my-debug"] = { inherits = "ghost-base" },
                        },
                    },
                },
            },
        })
        local diags = ws:diagnostics()
        local found = false
        for _, d in ipairs(diags) do
            if d.source == "Project/App/my-debug" then
                found = true
                assert.equals("warn", d.severity)
                assert.is_truthy(d.message:find("inherits from unknown", 1, true))
            end
        end
        assert.is_true(found,
            "expected unresolved-inherits diagnostic on my-debug")
    end)

    it("flags configuration sets with stale mappings (set-side view)", function()
        -- Same condition as above, viewed from the set's perspective.
        -- Both diagnostics fire — they answer different questions
        -- (project-side: 'this config is missing'; set-side:
        -- 'this set has broken refs').
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local diags = ws:diagnostics()
        local found = false
        for _, d in ipairs(diags) do
            if d.source == "ConfigurationSet/Debug" then
                found = true
                assert.equals("warn", d.severity)
                assert.is_truthy(d.message:find("stale mappings", 1, true))
                assert.equals("set:Debug", d.target_fold_key)
            end
        end
        assert.is_true(found,
            "expected a stale-mapping diagnostic for the set")
    end)

    it("flags unresolved inherits", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["my-debug"] = { inherits = "no-such-base" },
                        },
                    },
                },
            },
        })
        local diags = ws:diagnostics()
        local found = false
        for _, d in ipairs(diags) do
            if d.source == "Project/App/my-debug" then
                found = true
                assert.is_truthy(d.message:find("inherits from unknown bases", 1, true))
                assert.is_truthy(d.message:find("no-such-base", 1, true))
                assert.equals("config:App:my-debug", d.target_fold_key)
            end
        end
        assert.is_true(found,
            "expected an unresolved-inherits diagnostic")
    end)

    it("sorts by (severity, source) for stable output", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["zlast"] = { inherits = "no-such" },
                            ["aearly"] = { inherits = "no-such" },
                        },
                    },
                },
            },
        })
        local diags = ws:diagnostics()
        for i = 2, #diags do
            -- Within same severity, source is alphabetical.
            if diags[i - 1].severity == diags[i].severity then
                assert.is_true(diags[i - 1].source <= diags[i].source,
                    "diagnostics not sorted: " .. diags[i - 1].source
                    .. " before " .. diags[i].source)
            end
        end
    end)

    it("returns empty when configurations have no issues", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "variant:default" },
            },
        })
        assert.are.same({}, ws:diagnostics())
    end)
end)

-- ===========================================================================
-- :is_valid() — the predicate that operations gate on
-- ===========================================================================

describe(":is_valid()", function()
    it("Configuration: source-missing stub is invalid", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local stub = app:get_configuration("ghost-config")
        assert.is_not_nil(stub,
            "expected source-missing stub to live on the project")
        local ok, reasons = stub:is_valid()
        assert.is_false(ok)
        local found = false
        for _, r in ipairs(reasons) do
            if r:find("referenced but not defined", 1, true) then
                found = true; break
            end
        end
        assert.is_true(found, "reason should mention referenced-but-not-defined")
    end)

    it("Configuration: real auto-gen is valid", function()
        local ws = make_ws({ projects = { App = { typescript = {} } } })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local cfg = app:get_configuration("variant:default")
        local ok, reasons = cfg:is_valid()
        assert.is_true(ok)
        assert.are.same({}, reasons)
    end)

    it("Configuration: unresolved inherits is invalid", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["my-debug"] = { inherits = "no-such-base" },
                        },
                    },
                },
            },
        })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local cfg = app:get_configuration("my-debug")
        local ok = cfg:is_valid()
        assert.is_false(ok)
    end)

    it("ConfigurationSet: stale mapping makes set invalid", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local cs
        for _, c in ipairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end
        local ok, reasons = cs:is_valid()
        assert.is_false(ok)
        assert.is_truthy(reasons[1]:find("stale mappings", 1, true))
    end)

    it("ConfigurationSet: clean mappings → valid", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "variant:default" },
            },
        })
        local cs
        for _, c in ipairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end
        assert.is_true(cs:is_valid())
    end)

    it("source-missing stub is NOT written to user.json (no phantom)", function()
        -- Stubs preserve identity across reference breakage but
        -- must not materialise as on-disk configurations. The user
        -- didn't declare them; writing them out would be a silent
        -- creation of state.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        -- Force the project user-owned so it'd be a serialization
        -- candidate (otherwise the project isn't reached at all).
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        app:_mark_user_owned()

        local user_data = ws:_serialize_user()
        local cfgs = user_data.projects
            and user_data.projects.App
            and user_data.projects.App.typescript
            and user_data.projects.App.typescript.configurations or {}
        assert.is_nil(cfgs["ghost-config"],
            "source-missing stub leaked into user.json — it must not be persisted")
    end)

    it("source-missing stub's REFERENCE in config_set IS preserved on save", function()
        -- Distinct from the above: the *reference* to the missing
        -- name (in the config_set) must round-trip on save —
        -- otherwise we'd silently drop the user's intent. Only the
        -- phantom config gets filtered, the mapping survives.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local cs
        for _, c in ipairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end
        assert.is_not_nil(cs)
        local raw = cs:raw_mappings()
        assert.equals("ghost-config", raw.App,
            "stale mapping dropped — would silently clean user's intent")
    end)

    it("Profile: invalid set propagates to profile invalidity", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
            profiles = {
                ["Debug:noop"] = { configuration_set = "Debug" },
            },
        })
        local prof
        for _, p in ipairs(ws._profiles) do
            if p.key:find("Debug", 1, true) then prof = p; break end
        end
        assert.is_not_nil(prof)
        local ok, reasons = prof:is_valid()
        assert.is_false(ok,
            "profile with stale config_set ref should be invalid")
        local found = false
        for _, r in ipairs(reasons) do
            if r:find("configuration set", 1, true) then found = true; break end
        end
        assert.is_true(found,
            "profile invalidity reasons should cite the bad set")
    end)

    it("_type_config_for_module skips auto-gens to prevent is_user re-tagging",
       function()
        -- Regression: _type_config_for_module used to dump every
        -- live config (auto-gens included) into tc.configurations
        -- via serialize_user_override. canonicalize then re-tagged
        -- them as is_user=true, flipping is_default off. After a
        -- single _refresh_configurations call (triggered by any
        -- UI mutation), all auto-gens looked like user configs —
        -- which silently broke the diagnostic gate (is_valid had
        -- no _source_missing flag to read because the stubs were
        -- now classified as bona fide user configs).
        local ws = make_ws({
            projects = { App = { typescript = {} } },
        })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local tc = app:_type_config_for_module()
        local cfgs = tc.configurations or {}
        -- Auto-gen `variant:default` must NOT appear in the
        -- user_overrides slot, otherwise mod.info will re-tag it.
        assert.is_nil(cfgs["variant:default"],
            "auto-gen leaked into _type_config_for_module's user_overrides")
    end)

    it("_user_config_from_objects skips auto-gens (in-memory remerge cycle)",
       function()
        -- Regression: _user_config_from_objects iterates every
        -- _configurations entry where `_intent ~= "shared"`. Auto-gens
        -- get default_intent="local" (since they're not in either
        -- JSON file), so they passed the intent filter and ended up
        -- in the in-memory user_overlay. The next remerge passed
        -- that overlay to mod.info as user_overrides; canonicalize
        -- re-tagged every entry with is_user=true and the auto-gen
        -- → user-config flip silently broke the diagnostic gate.
        --
        -- Sibling of the _serialize_user fix and the
        -- _type_config_for_module fix; this third one runs every
        -- remerge cycle, not just on save or refresh.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
        })
        local overlay = ws:_user_config_from_objects()
        local cfgs = overlay.projects
            and overlay.projects.App
            and overlay.projects.App.type_config
            and overlay.projects.App.type_config.configurations or {}
        assert.is_nil(cfgs["variant:default"],
            "auto-gen leaked into in-memory user_overlay — "
            .. "next remerge will re-tag as is_user via canonicalize")
    end)

    it("source-missing stubs are also excluded from _type_config_for_module",
       function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local stub = app:get_configuration("ghost-config")
        assert.is_not_nil(stub,
            "expected source-missing stub in _configurations")
        assert.is_true(stub._source_missing)

        local tc = app:_type_config_for_module()
        local cfgs = tc.configurations or {}
        assert.is_nil(cfgs["ghost-config"],
            "source-missing stub leaked into _type_config_for_module — "
            .. "feeding it back to mod.info would materialise it as "
            .. "a real user config on the next refresh")
    end)

    it("source-missing stub: project-side diagnostic suppressed when set covers it",
       function()
        -- Regression: both ConfigurationSet:diagnostic (set-side
        -- view) and Configuration:diagnostic (project-side view)
        -- fired for the same stale mapping, doubling up on the
        -- status page. The set-side message is more actionable;
        -- the project-side is suppressed when source_missing is the
        -- only reason AND a set already references the stub.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local diags = ws:diagnostics()
        local set_count, proj_count = 0, 0
        for _, d in ipairs(diags) do
            if d.source:find("ConfigurationSet/", 1, true) then
                set_count = set_count + 1
            elseif d.source:find("Project/App/ghost-config", 1, true) then
                proj_count = proj_count + 1
            end
        end
        assert.equals(1, set_count, "set diagnostic should still fire")
        assert.equals(0, proj_count,
            "project-side diagnostic for the stub should be suppressed "
            .. "when the set already covers it")
    end)

    it("update_mapping GCs orphaned source-missing stub from project",
       function()
        -- Regression: after the user fixed a stale config_set mapping
        -- via update_mapping, the OLD stub stayed in
        -- project._configurations (full remerge wasn't triggered).
        -- The diagnostic kept firing until restart even though the
        -- mapping was clean. update_mapping now drops stubs that no
        -- referrer points at after the change.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local cs
        for _, c in ipairs(ws._config_sets) do
            if c.name == "Debug" then cs = c; break end
        end
        local stub = app:get_configuration("ghost-config")
        assert.is_not_nil(stub,
            "expected source-missing stub before update_mapping")

        -- Replace stale mapping with valid auto-gen.
        local valid = app:get_configuration("variant:default")
        assert.is_not_nil(valid)
        cs:update_mapping(app, valid)

        -- Stub should be dropped from project's configurations.
        local still_there = app:get_configuration("ghost-config")
        assert.is_nil(still_there,
            "orphaned stub should be GC'd from project after update_mapping")

        -- And no diagnostic should fire for the stub anymore.
        local diags = ws:diagnostics()
        for _, d in ipairs(diags) do
            assert.is_nil(d.source:find("ghost-config", 1, true),
                "stub diagnostic still firing after GC: " .. d.source)
        end
    end)

    it("update_mapping keeps stub when another set still references it",
       function()
        -- Defense: if two config_sets reference the same stale
        -- name, fixing one shouldn't drop the stub — the other is
        -- still holding it.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
                Release = { App = "ghost-config" },
            },
        })
        local app
        for _, p in ipairs(ws._projects) do
            if p.key == "App" then app = p; break end
        end
        local debug_cs, release_cs
        for _, c in ipairs(ws._config_sets) do
            if c.name == "Debug" then debug_cs = c
            elseif c.name == "Release" then release_cs = c end
        end
        -- Both sets pointed at the same stub object initially.
        local stub = app:get_configuration("ghost-config")
        assert.is_not_nil(stub)

        -- Fix only the Debug set.
        local valid = app:get_configuration("variant:default")
        debug_cs:update_mapping(app, valid)

        -- Release still references the stub → it should remain.
        local still_there = app:get_configuration("ghost-config")
        assert.is_not_nil(still_there,
            "stub was GC'd despite being referenced by Release set")
        assert.equals(stub, still_there, "stub identity preserved")
        -- Release set's mapping should still resolve to the stub.
        assert.equals(stub, release_cs.mappings[app])
    end)

    it("LaunchTarget:is_valid is the unified gate (resolution + validity)",
       function()
        -- Regression: LaunchTarget had two `is_valid` definitions —
        -- a domain-validity one (added with the diagnostics work) and
        -- the older descriptor-resolution one. The second shadowed
        -- the first. Now they're folded into a single tiered check.
        local LaunchTarget = require("loomworks.launch_target").LaunchTarget
            or require("loomworks.launch_target")

        -- Stale descriptor (no target / launch_config / device id)
        -- → tier-1 failure
        local stale = setmetatable({
            _profile = nil,
            _config_unit = nil,
            _target = nil,
            _launch_config = nil,
            _device_target_id = nil,
        }, { __index = LaunchTarget })
        local ok, reasons = stale:is_valid()
        assert.is_false(ok)
        assert.is_truthy(reasons[1]:find("no longer resolves", 1, true))

        -- Resolved descriptor + valid profile/config → ok
        local valid_target = setmetatable({
            _target = { name = "fake" },
            _profile = nil,
            _config_unit = nil,
        }, { __index = LaunchTarget })
        assert.is_true(valid_target:is_valid())

        -- Resolved descriptor + invalid profile → tier-2 failure
        local prof_with_reasons = {
            is_valid = function() return false, { "profile is incomplete" } end,
        }
        local invalid_profile_target = setmetatable({
            _target = { name = "fake" },
            _profile = prof_with_reasons,
            _config_unit = nil,
        }, { __index = LaunchTarget })
        local ok2, r2 = invalid_profile_target:is_valid()
        assert.is_false(ok2)
        assert.equals("profile is incomplete", r2[1])
    end)

    -- Compiler-family overrides + undeclared-variable references (core §1.3.1).
    describe("compiler-override diagnostics", function()
        it("flags an overrides block with an unknown compiler family", function()
            local ws = make_ws({
                projects = {
                    App = {
                        typescript = {
                            configurations = {
                                Custom = {
                                    inherits = "variant:default",
                                    overrides = { klang = { output_dir = "/o/klang" } },
                                },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "/o" },
                        },
                    },
                },
            })
            local diags = ws:diagnostics()
            local found
            for _, d in ipairs(diags) do
                if d.message:find("unknown compiler family", 1, true)
                    and d.message:find("klang", 1, true) then
                    found = d
                end
            end
            assert.is_not_nil(found, "expected an unknown-family diagnostic")
            assert.equals("warn", found.severity)
            assert.is_truthy(found.source:find("App/Custom", 1, true))
        end)

        it("flags an option that references an undeclared variable", function()
            local ws = make_ws({
                projects = {
                    App = {
                        typescript = {
                            configurations = {
                                Custom = {
                                    inherits = "variant:default",
                                    options = {
                                        GOOD = "${output_dir}",
                                        BAD = "${nonexistent_var_xyz}",
                                    },
                                },
                            },
                        },
                        variables = {
                            output_dir = { type = "path", default = "/o" },
                        },
                    },
                },
            })
            local diags = ws:diagnostics()
            local bad, good_leaked
            for _, d in ipairs(diags) do
                if d.message:find("undeclared variable", 1, true) then
                    if d.message:find("nonexistent_var_xyz", 1, true) then bad = d end
                    if d.message:find("output_dir", 1, true) then good_leaked = d end
                end
            end
            assert.is_not_nil(bad, "expected an undeclared-variable diagnostic for BAD")
            assert.is_nil(good_leaked, "declared variable must NOT be flagged")
            assert.is_truthy(bad.message:find("BAD", 1, true))
        end)
    end)
end)
