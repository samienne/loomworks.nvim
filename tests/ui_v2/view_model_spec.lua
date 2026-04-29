--- View-model tests for the v2 UI.
---
--- Exercises the presentation tree, selection, and inspector dispatch
--- against a real Workspace instance (same setup as integration_spec).
--- No nvim UI calls are made — the view model is pure presentation.

local workspace = require("loomworks.workspace")
local merge     = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h         = require("tests.helpers")
local Configuration = require("loomworks.configuration")

local Workspace = workspace.Workspace

local mock_modules = {
    cmake = {
        id = "cmake",
        has_keyed_tools = true,
        has_options = true,
        tools_match = function(a, b)
            if a == nil and b == nil then return true end
            if a == nil or b == nil then return false end
            return vim.deep_equal(a, b)
        end,
        default_configurations = function()
            return {
                Debug = { prefix = "variant", variant = "Debug" },
                Release = { prefix = "variant", variant = "Release" },
            }
        end,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        tool_key = function(tool_data) return tool_data.id end,
        tool_label = function(tool_data) return tool_data.display end,
        detect_tools_async = function(callback) callback({}) end,
        info = function(_, config)
            local defaults = {
                Debug = { prefix = "variant", variant = "Debug" },
                Release = { prefix = "variant", variant = "Release" },
            }
            return {
                configurations = Configuration.canonicalize(
                    defaults, config and config.configurations, "cmake"),
            }
        end,
    },
    typescript = {
        id = "typescript",
        has_keyed_tools = false,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        info = function(_, config)
            local defaults = { default = { prefix = "variant", variant = "default" } }
            return {
                configurations = Configuration.canonicalize(
                    defaults, config and config.configurations, "typescript"),
            }
        end,
    },
}

local function make_ws(config_overrides, user_overrides, cache_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local cache_json = cache_overrides and h.make_cache_json(cache_overrides) or nil

    local data = workspace.assemble("/root", config_json, user_json, cache_json)
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
            clock = function() return 0 end,
            now = function() return "2000-01-01T00:00:00Z" end,
            log = require("loomworks.log").test(),
        },
    }

    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws
end

local function fake_events()
    local listeners = {}
    return {
        on = function(event, fn)
            listeners[event] = listeners[event] or {}
            table.insert(listeners[event], fn)
        end,
        off = function(event, fn)
            local list = listeners[event] or {}
            for i, l in ipairs(list) do
                if l == fn then table.remove(list, i); return end
            end
        end,
        emit = function(event, data)
            for _, fn in ipairs(listeners[event] or {}) do fn(data) end
        end,
    }
end

local function make_vm(ws)
    local ViewModel = require("loomworks.ui.v2.view_model")
    return ViewModel.new({
        workspace_provider = function() return ws end,
        events = fake_events(),
    })
end

describe("ui v2 view model — overview presentation", function()
    it("returns no_workspace section when workspace is nil", function()
        local vm = make_vm(nil)
        local p = vm:presentation()
        assert.is_false(p.overview.initialised)
        assert.equals("no_workspace", p.overview.sections[1].kind)
    end)

    it("returns no_active_profile card when workspace has no active profile", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
        })
        local vm = make_vm(ws)
        local p = vm:presentation()
        assert.is_true(p.overview.initialised)
        assert.equals("no_active_profile", p.overview.sections[1].kind)
    end)

    it("builds active profile card with participating projects", function()
        local ws = make_ws(
            {
                projects = {
                    App      = { cmake = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    Debug = { App = "variant:Debug", Frontend = "variant:default" },
                },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local vm = make_vm(ws)
        local p = vm:presentation()

        local card = p.overview.sections[1]
        assert.equals("active_profile_card", card.kind)
        assert.equals("Debug", card.profile.key)
        assert.equals("Debug", card.profile.set)

        -- Two participating projects
        assert.equals(2, #card.projects)
        local project_keys = { card.projects[1].project_key, card.projects[2].project_key }
        table.sort(project_keys)
        assert.same({ "App", "Frontend" }, project_keys)
    end)

    it("includes other_profiles, other_projects, config_sets sections", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = {
                Debug = { App = "variant:Debug" },
            },
        })
        local vm = make_vm(ws)
        local kinds = {}
        for _, s in ipairs(vm:presentation().overview.sections) do
            kinds[s.kind] = true
        end
        assert.is_true(kinds.other_profiles)
        assert.is_true(kinds.other_projects)
        assert.is_true(kinds.config_sets)
    end)
end)

describe("ui v2 view model — selection and inspector dispatch", function()
    local function setup()
        local ws = make_ws(
            {
                projects = {
                    App      = { cmake = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    Debug = { App = "variant:Debug", Frontend = "variant:default" },
                },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        return ws, make_vm(ws)
    end

    it("default cursor (1,1) points at the active profile", function()
        local _, vm = setup()
        local p = vm:presentation()
        assert.equals("profile",       p.selection.effective_ref.kind)
        assert.equals("Debug",         p.selection.effective_ref.key)
        assert.equals("profile",       p.inspector.kind)
        assert.equals("Debug",         p.inspector.subject)
    end)

    it("cursor_to a project row updates the inspector subject", function()
        local _, vm = setup()
        -- The active profile card has selectable rows: [1]=profile, [2..]=projects.
        vm:dispatch("cursor_to", { section = 1, row = 2 })
        local p = vm:presentation()
        assert.equals("project", p.selection.effective_ref.kind)
        assert.equals("project", p.inspector.kind)
        -- Either App or Frontend, depending on profile.projects() ordering.
        local subject = p.inspector.subject
        assert.is_true(subject == "App" or subject == "Frontend",
            "expected App or Frontend, got " .. tostring(subject))
    end)

    it("toggle_pin freezes the inspector against subsequent cursor moves", function()
        local _, vm = setup()
        vm:dispatch("cursor_to", { section = 1, row = 2 })
        local pinned_subject = vm:presentation().inspector.subject
        vm:dispatch("toggle_pin")
        assert.is_not_nil(vm:presentation().selection.pinned)

        -- Move the cursor; inspector should NOT change.
        vm:dispatch("cursor_to", { section = 1, row = 1 })
        local p = vm:presentation()
        assert.equals(pinned_subject, p.inspector.subject)

        -- Toggle pin off; inspector should now follow cursor again.
        vm:dispatch("toggle_pin")
        assert.is_nil(vm:presentation().selection.pinned)
        local q = vm:presentation()
        assert.equals("Debug", q.inspector.subject)
    end)

    it("cursor on an unselectable row leaves inspector empty", function()
        local _, vm = setup()
        -- Section 2 is some collapsed section without selectable rows;
        -- pointing the cursor at row 1 should yield no ref.
        vm:dispatch("cursor_to", { section = 99, row = 1 })
        local p = vm:presentation()
        assert.is_nil(p.selection.effective_ref)
        assert.equals("empty", p.inspector.kind)
    end)
end)

describe("ui v2 view model — inspector content", function()
    it("project inspector exposes type, configurations, set membership", function()
        local ws = make_ws(
            {
                projects = {
                    App = { cmake = {
                        configurations = { ["my-debug"] = { inherits = "variant:Debug" } },
                    } },
                },
                configuration_sets = {
                    Debug = { App = "my-debug" },
                },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local vm = make_vm(ws)
        vm:dispatch("cursor_to", { section = 1, row = 2 }) -- App row

        local insp = vm:presentation().inspector
        assert.equals("project", insp.kind)
        assert.equals("App", insp.subject)
        assert.equals("cmake", insp.type)
        assert.is_true(#insp.configurations > 0)

        local membership_set_names = {}
        for _, m in ipairs(insp.set_membership) do
            membership_set_names[m.set_name] = m.variant_name
        end
        assert.equals("my-debug", membership_set_names.Debug)
    end)

    it("profile inspector exposes mappings and active flag", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local vm = make_vm(ws)
        local insp = vm:presentation().inspector
        assert.equals("profile", insp.kind)
        assert.equals("Debug", insp.subject)
        assert.is_true(insp.is_active)
        assert.equals("Debug", insp.configuration_set)
        assert.equals(1, #insp.mappings)
        assert.equals("App", insp.mappings[1].project_key)
    end)
end)

describe("ui v2 view model — section collapse/expand", function()
    local function setup()
        return make_ws(
            {
                projects = {
                    App      = { cmake = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    Debug   = { App = "variant:Debug",   Frontend = "variant:default" },
                    Release = { App = "variant:Release", Frontend = "variant:default" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug   = { configuration_set = "Debug" },
                    Release = { configuration_set = "Release" },
                },
            }
        )
    end

    it("config_sets section is collapsed by default and lists no items", function()
        local vm = make_vm(setup())
        local p = vm:presentation()
        local cs_section
        for _, s in ipairs(p.overview.sections) do
            if s.kind == "config_sets" then cs_section = s; break end
        end
        assert.is_not_nil(cs_section)
        assert.is_true(cs_section.collapsed)
        assert.equals(2, cs_section.count)
        assert.equals(0, #(cs_section.items or {}))
    end)

    it("toggle_section expands config_sets and populates items + selectable", function()
        local vm = make_vm(setup())
        vm:dispatch("toggle_section", { kind = "config_sets" })
        local p = vm:presentation()
        local cs_section
        for _, s in ipairs(p.overview.sections) do
            if s.kind == "config_sets" then cs_section = s; break end
        end
        assert.is_false(cs_section.collapsed)
        assert.equals(2, #cs_section.items)
        assert.equals(2, #cs_section.selectable)

        local names = { cs_section.items[1].name, cs_section.items[2].name }
        table.sort(names)
        assert.same({ "Debug", "Release" }, names)
    end)

    it("other_profiles expansion lists non-active profiles", function()
        local vm = make_vm(setup())
        vm:dispatch("toggle_section", { kind = "other_profiles" })
        local p = vm:presentation()
        local op
        for _, s in ipairs(p.overview.sections) do
            if s.kind == "other_profiles" then op = s; break end
        end
        assert.equals(1, #op.items, "Release should be the only other profile")
        assert.equals("Release", op.items[1].key)
    end)

    it("cursor on an expanded config_set row dispatches to config_set inspector", function()
        local vm = make_vm(setup())
        vm:dispatch("toggle_section", { kind = "config_sets" })
        local p = vm:presentation()
        -- Find the config_sets section index
        local cs_idx
        for i, s in ipairs(p.overview.sections) do
            if s.kind == "config_sets" then cs_idx = i; break end
        end
        vm:dispatch("cursor_to", { section = cs_idx, row = 1 })
        local q = vm:presentation()
        assert.equals("config_set", q.selection.effective_ref.kind)
        assert.equals("config_set", q.inspector.kind)
    end)
end)

describe("ui v2 view model — config_set inspector", function()
    it("shows mappings and used_by profiles", function()
        local ws = make_ws(
            {
                projects = {
                    App      = { cmake = {} },
                    Frontend = { typescript = {} },
                },
                configuration_sets = {
                    Debug = { App = "variant:Debug", Frontend = "variant:default" },
                },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local ViewModel = require("loomworks.ui.v2.view_model")
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, { kind = "config_set", key = "Debug" })

        assert.equals("config_set", insp.kind)
        assert.equals("Debug", insp.subject)
        assert.equals(2, #insp.mappings)
        assert.equals(1, #insp.used_by)
        assert.equals("Debug", insp.used_by[1])
    end)

    it("returns missing=true for an unknown set name", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, { kind = "config_set", key = "Nonexistent" })
        assert.is_true(insp.missing)
    end)
end)

describe("ui v2 view model — configuration inspector", function()
    it("shows variant fields for a user configuration with inherits", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["my-debug"] = { inherits = "variant:Debug" },
                        },
                    },
                },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "configuration",
            project_key = "App",
            config_name = "my-debug",
        })
        assert.equals("configuration", insp.kind)
        assert.equals("my-debug", insp.subject)
        assert.equals("App", insp.project_key)
        assert.is_true(insp.is_user)
        assert.is_false(insp.source_missing)
        assert.is_true(#insp.inherits >= 1, "inherits should contain at least variant:Debug")
    end)

    it("returns missing for an unknown configuration name", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "configuration",
            project_key = "App",
            config_name = "no-such-config",
        })
        assert.is_true(insp.missing)
    end)
end)

describe("ui v2 view model — launch inspector", function()
    it("shows command, args, env for a typescript project launch", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = {
                        debug = {
                            command = "node",
                            args = { "app.js", "--port", "9229" },
                            env = { NODE_ENV = "development" },
                            working_dir = "/wd",
                        },
                    },
                },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "launch",
            project_key = "App",
            launch_name = "debug",
        })
        assert.equals("launch", insp.kind)
        assert.equals("debug", insp.subject)
        assert.equals("App", insp.project_key)
        assert.equals("node", insp.command)
        assert.same({ "app.js", "--port", "9229" }, insp.args)
        assert.equals(1, #insp.env)
        assert.equals("NODE_ENV", insp.env[1].key)
        assert.equals("development", insp.env[1].value)
        assert.equals("/wd", insp.working_dir)
        assert.equals(0, insp.deploy_count)
    end)

    it("returns missing for an unknown launch name", function()
        local ws = make_ws({ projects = { App = { typescript = {} } } })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "launch",
            project_key = "App",
            launch_name = "ghost",
        })
        assert.is_true(insp.missing)
    end)
end)

describe("ui v2 view model — hint bar", function()
    it("overview presentation includes a hint_bar", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        local p = vm:presentation()
        assert.is_table(p.overview.hint_bar)
        assert.is_true(#p.overview.hint_bar > 0)
        local labels = {}
        for _, h in ipairs(p.overview.hint_bar) do labels[h.key] = h.label end
        assert.equals("close", labels.q)
        assert.equals("toggle", labels.o)
        assert.equals("pin", labels.p)
    end)

    it("inspector kinds populate their own hint_bar", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local vm = make_vm(ws)
        local p = vm:presentation()
        assert.is_table(p.inspector.hint_bar)
        assert.is_true(#p.inspector.hint_bar > 0)
    end)
end)

describe("ui v2 overview view — highlight emission", function()
    local overview_view = require("loomworks.ui.v2.view.overview_view")
    local overview_vm   = require("loomworks.ui.v2.view_model.overview")

    it("emits a LoomworksActive highlight on the active profile row", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local presentation = overview_vm.build(ws, {})
        local _, highlights = overview_view.render(presentation, { cursor = { section = 1, row = 1 } })
        local found_active = false
        for _, h in ipairs(highlights) do
            if h.hl_group == "LoomworksActive" then found_active = true; break end
        end
        assert.is_true(found_active, "expected at least one LoomworksActive highlight")
    end)

    it("emits a LoomworksFailed highlight when a project's state is configure_failed", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            },
            {
                configurations = {
                    ["App/variant:Debug"] = {
                        project_key = "App",
                        config_key = "variant:Debug",
                        variant = "variant:Debug",
                        type = "cmake",
                        state = "failed_configure",
                    },
                },
            }
        )
        local presentation = overview_vm.build(ws, {})
        local _, highlights = overview_view.render(presentation, { cursor = { section = 1, row = 1 } })
        local found_failed = false
        for _, h in ipairs(highlights) do
            if h.hl_group == "LoomworksFailed" then found_failed = true; break end
        end
        assert.is_true(found_failed, "expected a LoomworksFailed highlight on the failed row")
    end)

    it("emits Comment highlights on collapsed section headers", function()
        local ws = make_ws({
            projects = { App = { cmake = {} } },
            configuration_sets = { Debug = { App = "variant:Debug" } },
        })
        local presentation = overview_vm.build(ws, {}) -- defaults: most sections collapsed
        local _, highlights = overview_view.render(presentation, { cursor = { section = 1, row = 1 } })
        local comment_hits = 0
        for _, h in ipairs(highlights) do
            if h.hl_group == "Comment" then comment_hits = comment_hits + 1 end
        end
        assert.is_true(comment_hits >= 1, "expected at least one Comment highlight")
    end)
end)

describe("ui v2 inspector view — highlight emission", function()
    local inspector_view = require("loomworks.ui.v2.view.inspector_view")
    local inspector_vm   = require("loomworks.ui.v2.view_model.inspector")

    it("renders a Title line for the inspector subject", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local insp = inspector_vm.build(ws, { kind = "project", key = "App" })
        local _, highlights = inspector_view.render(insp)
        local has_title = false
        for _, h in ipairs(highlights) do
            if h.hl_group == "Title" then has_title = true; break end
        end
        assert.is_true(has_title)
    end)

    it("renders LoomworksActive on a profile inspector when is_active = true", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local insp = inspector_vm.build(ws, { kind = "profile", key = "Debug" })
        local _, highlights = inspector_view.render(insp)
        local has_active = false
        for _, h in ipairs(highlights) do
            if h.hl_group == "LoomworksActive" then has_active = true; break end
        end
        assert.is_true(has_active)
    end)
end)

describe("ui v2 view model — variable inspector", function()
    it("shows declaration + per-config overrides", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["my-debug"] = {
                                inherits  = "variant:Debug",
                                variables = { output_dir = "${project_path}/dist/debug" },
                            },
                        },
                    },
                    variables = {
                        output_dir = { type = "path", default = "${project_path}/dist" },
                    },
                },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "variable", project_key = "App", var_name = "output_dir",
        })
        assert.equals("variable", insp.kind)
        assert.equals("output_dir", insp.subject)
        assert.equals("path", insp.type)
        assert.equals("${project_path}/dist", insp.default)
        assert.equals(1, #insp.overrides)
        assert.equals("my-debug", insp.overrides[1].configuration_name)
        assert.equals("${project_path}/dist/debug", insp.overrides[1].value)
    end)

    it("returns missing for an unknown variable", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "variable", project_key = "App", var_name = "nope",
        })
        assert.is_true(insp.missing)
    end)
end)

describe("ui v2 view model — device inspector", function()
    local function ws_with_fake_device()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        -- Inject a fake device — devices are runtime-only.
        ws._devices = ws._devices or {}
        ws._devices.SERIAL1 = {
            serial = "SERIAL1",
            display_name = "Test Phone",
            provider = "harmony",
            state = "online",
            properties = { model = "TPX1", os = "OpenHarmony 5.0" },
        }
        return ws
    end

    it("renders fields and properties for an online device", function()
        local ws = ws_with_fake_device()
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, { kind = "device", key = "SERIAL1" })
        assert.equals("device", insp.kind)
        assert.equals("SERIAL1", insp.subject)
        assert.equals("Test Phone", insp.display_name)
        assert.equals("harmony", insp.provider)
        assert.equals("online", insp.state)
        assert.equals(2, #insp.properties)
        local keys = {}
        for _, p in ipairs(insp.properties) do keys[p.key] = p.value end
        assert.equals("TPX1", keys.model)
    end)

    it("returns missing for an unknown serial", function()
        local ws = ws_with_fake_device()
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, { kind = "device", key = "GHOST" })
        assert.is_true(insp.missing)
    end)
end)

describe("ui v2 view model — deploy_step inspector", function()
    it("reads a single-source launch-level deploy step", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = {
                        debug = {
                            command = "node",
                            args = { "app.js" },
                            deploy = {
                                ["${build_dir}/native.node"] = {
                                    project = "NativeLib",
                                    target = "native_lib",
                                },
                            },
                        },
                    },
                },
                NativeLib = { cmake = {} },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "deploy_step",
            project_key = "App",
            launch_name = "debug",
            destination = "${build_dir}/native.node",
        })
        assert.equals("deploy_step", insp.kind)
        assert.equals("launch", insp.scope)
        assert.equals("App", insp.project_key)
        assert.equals(1, #insp.sources)
        assert.equals("NativeLib", insp.sources[1].project)
        assert.equals("native_lib", insp.sources[1].target)
        assert.is_false(insp.sources[1].pre_build)
    end)

    it("reads an array source and pre_build phase", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = {
                        debug = {
                            command = "node",
                            args = { "app.js" },
                            deploy = {
                                ["${build_dir}/lib/"] = {
                                    { project = "A", target = "x" },
                                    { project = "B", path = "y", pre_build = true },
                                },
                            },
                        },
                    },
                },
                A = { cmake = {} },
                B = { cmake = {} },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "deploy_step",
            project_key = "App",
            launch_name = "debug",
            destination = "${build_dir}/lib/",
        })
        assert.equals(2, #insp.sources)
        assert.equals("A", insp.sources[1].project)
        assert.is_true(insp.sources[2].pre_build)
    end)

    it("returns missing when destination is unknown", function()
        local ws = make_ws({ projects = { App = { typescript = {} } } })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "deploy_step",
            project_key = "App",
            launch_name = "debug",
            destination = "/somewhere",
        })
        assert.is_true(insp.missing)
    end)
end)

describe("ui v2 view model — activity strip", function()
    local activity_vm   = require("loomworks.ui.v2.view_model.activity")
    local activity_view = require("loomworks.ui.v2.view.activity_view")

    it("returns has_workspace=false when there is no workspace", function()
        local p = activity_vm.build(nil)
        assert.is_false(p.has_workspace)
        assert.equals(0, p.running_count)
    end)

    it("reports zero running tasks for a fresh workspace", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local p = activity_vm.build(ws)
        assert.is_true(p.has_workspace)
        assert.equals(0, p.running_count)
    end)

    it("emits a row when a ConfigUnit has a running action", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        -- Mark a config unit as running configure.
        for _, unit in pairs(ws._config_units or {}) do
            unit._action = "configure"
            unit._start_time = 0
            unit._progress = { current = 3, total = 10, message = "configuring" }
            break
        end
        local p = activity_vm.build(ws)
        assert.equals(1, p.running_count)
        assert.equals("configure", p.running[1].action)
        assert.equals(3,           p.running[1].current)
        assert.equals(10,          p.running[1].total)
        assert.equals(30,          p.running[1].percent)
    end)

    it("renders 'no running tasks' when nothing is in flight", function()
        local p = activity_vm.build(make_ws({ projects = { App = { cmake = {} } } }))
        local lines, _ = activity_view.render(p)
        local found = false
        for _, l in ipairs(lines) do
            if l:find("no running tasks") then found = true; break end
        end
        assert.is_true(found)
    end)

    it("renders one line per running task with progress and elapsed", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        for _, unit in pairs(ws._config_units or {}) do
            unit._action = "build"
            unit._start_time = 0
            unit._progress = { current = 8, total = 10 }
            break
        end
        local p = activity_vm.build(ws)
        local lines, _ = activity_view.render(p)
        local has_running = false
        for _, l in ipairs(lines) do
            if l:find("80%%") and l:find("App") then has_running = true; break end
        end
        assert.is_true(has_running, "expected a row with App and 80%% progress")
    end)
end)

describe("ui v2 view model — presentation includes activity", function()
    it("activity is part of the root presentation tree", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        local p = vm:presentation()
        assert.is_table(p.activity)
        assert.is_true(p.activity.has_workspace)
        assert.is_table(p.activity.hint_bar)
    end)
end)

describe("ui v2 view model — inspector drill-in", function()
    local function setup()
        return make_ws(
            {
                projects = {
                    App = {
                        cmake = {
                            configurations = {
                                ["my-debug"] = { inherits = "variant:Debug" },
                            },
                        },
                        launch = {
                            debug = { command = "node", args = { "app.js" } },
                        },
                    },
                },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
    end

    it("project inspector emits drill refs for configurations and launches", function()
        local ws = setup()
        local vm = make_vm(ws)
        -- Move cursor to App project in active card.
        vm:dispatch("cursor_to", { section = 1, row = 2 })
        local p = vm:presentation()
        assert.equals("project", p.inspector.kind)

        -- Find a configuration row that carries a drill ref.
        local found_config_ref = false
        for _, cfg in ipairs(p.inspector.configurations) do
            if cfg.ref and cfg.ref.kind == "configuration" then
                found_config_ref = true; break
            end
        end
        assert.is_true(found_config_ref)

        -- Launches should also carry drill refs.
        local launch_ref
        for _, l in ipairs(p.inspector.launches) do
            if l.ref then launch_ref = l.ref; break end
        end
        assert.is_not_nil(launch_ref)
        assert.equals("launch", launch_ref.kind)
    end)

    it("drill_in pins inspector to the new ref", function()
        local ws = setup()
        local vm = make_vm(ws)
        vm:dispatch("cursor_to", { section = 1, row = 2 }) -- App project

        -- Drill into a configuration.
        vm:dispatch("drill_in", {
            ref = { kind = "configuration", project_key = "App", config_name = "my-debug" },
        })

        local p = vm:presentation()
        assert.equals("configuration", p.inspector.kind)
        assert.equals("my-debug", p.inspector.subject)
        assert.is_not_nil(p.selection.pinned)

        -- Move overview cursor — inspector should remain pinned.
        vm:dispatch("cursor_to", { section = 1, row = 1 }) -- profile row
        local q = vm:presentation()
        assert.equals("configuration", q.inspector.kind)
        assert.equals("my-debug", q.inspector.subject)

        -- Toggle pin off — inspector returns to overview-cursor selection.
        vm:dispatch("toggle_pin")
        local r = vm:presentation()
        assert.equals("profile", r.inspector.kind)
    end)

    it("inspector view renders drill refs as selectable lines", function()
        local ws = setup()
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, { kind = "project", key = "App" })
        local inspector_view = require("loomworks.ui.v2.view.inspector_view")
        local _, _, drill_map = inspector_view.render(insp)
        assert.is_table(drill_map)
        local saw_config_ref = false
        for _, ref in pairs(drill_map) do
            if ref.kind == "configuration" then saw_config_ref = true; break end
        end
        assert.is_true(saw_config_ref)
    end)
end)

describe("ui v2 view model — action key dispatch", function()
    local function setup_two_profiles()
        return make_ws(
            {
                projects = {
                    App = { cmake = {} },
                },
                configuration_sets = {
                    Debug   = { App = "variant:Debug" },
                    Release = { App = "variant:Release" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug   = { configuration_set = "Debug" },
                    Release = { configuration_set = "Release" },
                },
            }
        )
    end

    it("resolve_action_target returns the profile when cursor is on the active profile row", function()
        local ws = setup_two_profiles()
        local vm = make_vm(ws)
        -- Default cursor is on the active profile row (section 1, row 1)
        local t = vm:resolve_action_target()
        assert.equals("profile", t.kind)
        assert.equals("Debug", t.target.key)
    end)

    it("resolve_action_target returns config_unit on a project row in the active card", function()
        local ws = setup_two_profiles()
        local vm = make_vm(ws)
        vm:dispatch("cursor_to", { section = 1, row = 2 }) -- App project row
        local t = vm:resolve_action_target()
        assert.equals("config_unit", t.kind)
        assert.is_not_nil(t.target)
        assert.is_not_nil(t.profile)
        assert.equals("Debug", t.profile.key)
    end)

    it("resolve_action_target returns nil when cursor is on a non-actionable section", function()
        local ws = setup_two_profiles()
        local vm = make_vm(ws)
        -- Cursor on a non-existent section
        vm:dispatch("cursor_to", { section = 99, row = 1 })
        local t = vm:resolve_action_target()
        assert.is_nil(t)
    end)

    it("act_under_cursor activate switches the active profile", function()
        local ws = setup_two_profiles()
        local vm = make_vm(ws)
        -- Expand 'other_profiles' and put cursor on Release
        vm:dispatch("toggle_section", { kind = "other_profiles" })
        local p = vm:presentation()
        local op_idx
        for i, s in ipairs(p.overview.sections) do
            if s.kind == "other_profiles" then op_idx = i; break end
        end
        vm:dispatch("cursor_to", { section = op_idx, row = 1 }) -- Release
        assert.equals("Debug", ws._active_profile.key)

        vm:dispatch("act_under_cursor", { action = "activate" })
        assert.equals("Release", ws._active_profile.key)
    end)

    it("act_under_cursor build calls profile:build via the routed profile", function()
        local ws = setup_two_profiles()
        local vm = make_vm(ws)
        local called = {}
        local profile = ws._active_profile
        local original = profile.build
        profile.build = function(self, opts)
            called.profile_key = self.key
            called.opts = opts
            return { _stub = true }
        end

        vm:dispatch("act_under_cursor", { action = "build" })
        assert.equals("Debug", called.profile_key)

        profile.build = original
    end)

    it("act_under_cursor delete on a project row calls config_unit:delete", function()
        local ws = setup_two_profiles()
        local vm = make_vm(ws)
        vm:dispatch("cursor_to", { section = 1, row = 2 }) -- App project row

        local target = vm:resolve_action_target()
        assert.equals("config_unit", target.kind)

        local called = false
        local original = target.target.delete
        target.target.delete = function() called = true; return { _stub = true } end

        vm:dispatch("act_under_cursor", { action = "delete" })
        assert.is_true(called)

        target.target.delete = original
    end)
end)

describe("ui v2 view model — cycle_publish", function()
    it("cycles a profile's intent local → local+shared → shared → local", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local vm = make_vm(ws)
        local profile = ws._active_profile
        assert.equals("local", profile._intent or "local")

        vm:dispatch("cycle_publish")
        assert.equals("local+shared", profile._intent)

        vm:dispatch("cycle_publish")
        assert.equals("shared", profile._intent)

        vm:dispatch("cycle_publish")
        assert.equals("local", profile._intent)
    end)

    it("cycles a project's intent when inspector subject is a project", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        vm:dispatch("drill_in", { ref = { kind = "project", key = "App" } })

        local function find_project(key)
            for _, p in pairs(ws._projects or {}) do
                if p.key == key then return p end
            end
        end
        local proj = find_project("App")
        local before = proj._intent or "local"
        vm:dispatch("cycle_publish")
        assert.is_not.equal(before, proj._intent)
    end)

    it("publish line in inspector reflects current intent", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        local vm = make_vm(ws)
        local p = vm:presentation()
        assert.is_true(p.inspector.publishable)
        assert.equals("local", p.inspector.intent)

        vm:dispatch("cycle_publish")
        local q = vm:presentation()
        assert.equals("local+shared", q.inspector.intent)
    end)

    it("is a no-op when inspector subject is non-publishable (e.g. variable)", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {},
                    variables = { x = { type = "string", default = "y" } },
                },
            },
        })
        local vm = make_vm(ws)
        local function find_project(key)
            for _, p in pairs(ws._projects or {}) do
                if p.key == key then return p end
            end
        end
        local proj = find_project("App")
        local before = proj._intent

        vm:dispatch("drill_in", {
            ref = { kind = "variable", project_key = "App", var_name = "x" },
        })
        vm:dispatch("cycle_publish")
        assert.equals(before, proj._intent,
            "non-publishable inspector subject must not mutate any project intent")
    end)
end)

describe("ui v2 view model — set_field on text fields", function()
    it("set_field updates a launch config's command via Project:save_launch_config", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = {
                        debug = { command = "node", args = { "old.js" } },
                    },
                },
            },
        })
        local vm = make_vm(ws)

        vm:dispatch("set_field", {
            subject  = { kind = "launch", project_key = "App", launch_name = "debug" },
            field_id = "command",
            value    = "deno",
        })

        local function find_project(key)
            for _, p in pairs(ws._projects or {}) do if p.key == key then return p end end
        end
        local proj = find_project("App")
        assert.equals("deno", proj.launch.debug.command)
        -- args should be preserved (we updated only the command field)
        assert.same({ "old.js" }, proj.launch.debug.args)
    end)

    it("set_field updates a variable's default via Project:save_variable", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    variables = { output_dir = { type = "path", default = "${project_path}/dist" } },
                },
            },
        })
        local vm = make_vm(ws)

        vm:dispatch("set_field", {
            subject  = { kind = "variable", project_key = "App", var_name = "output_dir" },
            field_id = "default",
            value    = "${project_path}/build",
        })

        local function find_project(key)
            for _, p in pairs(ws._projects or {}) do if p.key == key then return p end end
        end
        local proj = find_project("App")
        assert.equals("${project_path}/build", proj.variables.output_dir.default)
        -- type preserved
        assert.equals("path", proj.variables.output_dir.type)
    end)

    it("inspector view emits editable_at_line for launch.command", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = { debug = { command = "node", args = { "x" } } },
                },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "launch", project_key = "App", launch_name = "debug",
        })
        local inspector_view = require("loomworks.ui.v2.view.inspector_view")
        local _, _, _, edit_map = inspector_view.render(insp)
        local found_command = false
        for _, field in pairs(edit_map) do
            if field.id == "command" and field.subject.kind == "launch" then
                found_command = true
                assert.equals("node", field.value)
                break
            end
        end
        assert.is_true(found_command)
    end)

    it("returns false on unknown subject.kind", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        -- This shouldn't raise; the dispatch handles unknowns by no-op.
        vm:dispatch("set_field", {
            subject  = { kind = "nope", project_key = "App" },
            field_id = "anything",
            value    = "x",
        })
    end)
end)

describe("ui v2 view model — configuration_option editing", function()
    local function find_project(ws, key)
        for _, p in pairs(ws._projects or {}) do if p.key == key then return p end end
    end

    it("set_field on a user configuration option updates and persists", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["my-debug"] = {
                                inherits = "variant:Debug",
                                options = { BUILD_TESTS = "OFF" },
                            },
                        },
                    },
                },
            },
        })
        local vm = make_vm(ws)

        vm:dispatch("set_field", {
            subject  = {
                kind = "configuration_option",
                project_key = "App",
                config_name = "my-debug",
                option_key  = "BUILD_TESTS",
            },
            field_id = "option:BUILD_TESTS",
            value    = "ON",
        })

        local cfg = find_project(ws, "App"):get_configuration("my-debug")
        assert.equals("ON", cfg.options.BUILD_TESTS)
    end)

    it("set_field on an auto-gen configuration option does nothing", function()
        local ws = make_ws({
            projects = {
                App = { cmake = {} },  -- only auto-gen Debug/Release exist
            },
        })
        local vm = make_vm(ws)

        local cfg = find_project(ws, "App"):get_configuration("variant:Debug")
        assert.is_not_nil(cfg)
        assert.is_false(cfg.is_user)

        -- Attempting to edit an auto-gen option must not raise
        vm:dispatch("set_field", {
            subject  = {
                kind = "configuration_option",
                project_key = "App",
                config_name = "variant:Debug",
                option_key  = "BUILD_TESTS",
            },
            field_id = "option:BUILD_TESTS",
            value    = "ON",
        })
        -- Original config remains unchanged
        assert.is_nil((cfg.options or {}).BUILD_TESTS)
    end)

    it("clearing an option (empty value) removes it", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["my-debug"] = {
                                inherits = "variant:Debug",
                                options = { BUILD_TESTS = "ON", USE_LTO = "ON" },
                            },
                        },
                    },
                },
            },
        })
        local vm = make_vm(ws)

        vm:dispatch("set_field", {
            subject  = {
                kind = "configuration_option",
                project_key = "App",
                config_name = "my-debug",
                option_key  = "BUILD_TESTS",
            },
            field_id = "option:BUILD_TESTS",
            value    = "",
        })

        local cfg = find_project(ws, "App"):get_configuration("my-debug")
        assert.is_nil(cfg.options.BUILD_TESTS)
        assert.equals("ON", cfg.options.USE_LTO)
    end)

    it("inspector view emits editable_at_line for each user-config option", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {
                        configurations = {
                            ["my-debug"] = {
                                inherits = "variant:Debug",
                                options = { BUILD_TESTS = "ON" },
                            },
                        },
                    },
                },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "configuration", project_key = "App", config_name = "my-debug",
        })
        local inspector_view = require("loomworks.ui.v2.view.inspector_view")
        local _, _, _, edit_map = inspector_view.render(insp)
        local found = false
        for _, field in pairs(edit_map) do
            if field.subject and field.subject.kind == "configuration_option" then
                found = true
                assert.equals("BUILD_TESTS", field.subject.option_key)
                break
            end
        end
        assert.is_true(found)
    end)
end)

describe("ui v2 view model — add_item", function()
    local function find_project(ws, key)
        for _, p in pairs(ws._projects or {}) do if p.key == key then return p end end
    end

    it("add_item kind=variable creates the variable with defaults", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind   = "variable",
            parent = { kind = "project", key = "App" },
            name   = "new_var",
        })
        local proj = find_project(ws, "App")
        assert.is_not_nil(proj.variables and proj.variables.new_var)
        assert.equals("string", proj.variables.new_var.type)
        assert.equals("", proj.variables.new_var.default)
    end)

    it("add_item kind=launch creates a launch with empty command", function()
        local ws = make_ws({ projects = { App = { typescript = {} } } })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind   = "launch",
            parent = { kind = "project", key = "App" },
            name   = "newlaunch",
        })
        local proj = find_project(ws, "App")
        assert.is_not_nil(proj.launch and proj.launch.newlaunch)
        assert.equals("", proj.launch.newlaunch.command)
    end)

    it("add_item kind=configuration creates a user configuration inheriting a variant", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind   = "configuration",
            parent = { kind = "project", key = "App" },
            name   = "my-debug",
        })
        local proj = find_project(ws, "App")
        local cfg = proj:get_configuration("my-debug")
        assert.is_not_nil(cfg)
        assert.is_true(cfg.is_user)
    end)

    it("add_item pins the inspector to the freshly added item", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind   = "variable",
            parent = { kind = "project", key = "App" },
            name   = "fresh",
        })
        local p = vm:presentation()
        assert.is_not_nil(p.selection.pinned)
        assert.equals("variable", p.selection.pinned.kind)
        assert.equals("fresh",    p.selection.pinned.var_name)
    end)

    it("project inspector exposes + Add sentinels via the renderer", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, { kind = "project", key = "App" })
        local inspector_view = require("loomworks.ui.v2.view.inspector_view")
        local _, _, _, _, add_map = inspector_view.render(insp)
        local kinds_seen = {}
        for _, descriptor in pairs(add_map) do kinds_seen[descriptor.kind] = true end
        assert.is_true(kinds_seen.variable)
        assert.is_true(kinds_seen.launch)
        assert.is_true(kinds_seen.configuration)
    end)
end)

describe("ui v2 view model — deploy_step add", function()
    local function find_project(ws, key)
        for _, p in pairs(ws._projects or {}) do if p.key == key then return p end end
    end

    it("add_item kind=deploy_step adds a target source descriptor", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = { debug = { command = "node", args = { "x" } } },
                },
                NativeLib = { cmake = {} },
            },
        })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind = "deploy_step",
            parent = { kind = "launch", project_key = "App", launch_name = "debug" },
            name = "${build_dir}/native.node",
            extra = { source_project = "NativeLib", target = "native_lib" },
        })

        local proj = find_project(ws, "App")
        local d = proj.launch.debug.deploy
        assert.is_not_nil(d)
        local entry = d["${build_dir}/native.node"]
        assert.is_not_nil(entry)
        assert.equals("NativeLib", entry.project)
        assert.equals("native_lib", entry.target)
    end)

    it("add_item kind=deploy_step adds a path source descriptor", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = { debug = { command = "node" } },
                },
                B = { cmake = {} },
            },
        })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind = "deploy_step",
            parent = { kind = "launch", project_key = "App", launch_name = "debug" },
            name = "${build_dir}/file",
            extra = { source_project = "B", path = "lib/x.so" },
        })

        local proj = find_project(ws, "App")
        local entry = proj.launch.debug.deploy["${build_dir}/file"]
        assert.equals("lib/x.so", entry.path)
    end)

    it("rejects when extra has neither target nor path", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = { debug = { command = "node" } },
                },
                NativeLib = { cmake = {} },
            },
        })
        local vm = make_vm(ws)
        vm:dispatch("add_item", {
            kind = "deploy_step",
            parent = { kind = "launch", project_key = "App", launch_name = "debug" },
            name = "${build_dir}/x",
            extra = { source_project = "NativeLib" },
        })
        local proj = find_project(ws, "App")
        assert.is_nil(proj.launch.debug.deploy)
    end)

    it("launch inspector exposes deploy_steps refs and the + Add deploy step sentinel", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = {
                        debug = {
                            command = "node",
                            deploy = {
                                ["${build_dir}/x.so"] = { project = "B", path = "x.so" },
                            },
                        },
                    },
                },
                B = { cmake = {} },
            },
        })
        local inspector = require("loomworks.ui.v2.view_model.inspector")
        local insp = inspector.build(ws, {
            kind = "launch", project_key = "App", launch_name = "debug",
        })
        assert.equals(1, #insp.deploy_steps)
        assert.equals("${build_dir}/x.so", insp.deploy_steps[1].destination)
        assert.equals("deploy_step", insp.deploy_steps[1].ref.kind)
        assert.is_not_nil(insp.add_actions and insp.add_actions.deploy_step)

        local inspector_view = require("loomworks.ui.v2.view.inspector_view")
        local _, _, drill_map, _, add_map = inspector_view.render(insp)
        local has_step_ref = false
        for _, ref in pairs(drill_map) do
            if ref.kind == "deploy_step" then has_step_ref = true; break end
        end
        assert.is_true(has_step_ref)
        local has_add = false
        for _, descriptor in pairs(add_map) do
            if descriptor.kind == "deploy_step" then has_add = true; break end
        end
        assert.is_true(has_add)
    end)
end)

describe("ui v2 view model — delete_inspector_subject", function()
    local function find_project(ws, key)
        for _, p in pairs(ws._projects or {}) do if p.key == key then return p end end
    end

    it("deletes a deploy step from a launch config", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {},
                    launch = {
                        debug = {
                            command = "node",
                            deploy = {
                                ["a"] = { project = "B", target = "x" },
                                ["b"] = { project = "B", path = "y" },
                            },
                        },
                    },
                },
                B = { cmake = {} },
            },
        })
        local vm = make_vm(ws)
        vm:dispatch("drill_in", {
            ref = { kind = "deploy_step", project_key = "App", launch_name = "debug", destination = "a" },
        })
        vm:dispatch("delete_inspector_subject")

        local proj = find_project(ws, "App")
        assert.is_nil(proj.launch.debug.deploy["a"])
        assert.is_not_nil(proj.launch.debug.deploy["b"])
    end)

    it("deletes a variable", function()
        local ws = make_ws({
            projects = {
                App = {
                    cmake = {},
                    variables = { x = { type = "string", default = "y" } },
                },
            },
        })
        local vm = make_vm(ws)
        vm:dispatch("drill_in", {
            ref = { kind = "variable", project_key = "App", var_name = "x" },
        })
        vm:dispatch("delete_inspector_subject")

        local proj = find_project(ws, "App")
        assert.is_nil(proj.variables and proj.variables.x)
    end)

    it("does nothing when inspector is empty or missing", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local vm = make_vm(ws)
        -- Pin to a non-existent item; inspector shows missing=true
        vm:dispatch("drill_in", {
            ref = { kind = "variable", project_key = "App", var_name = "ghost" },
        })
        vm:dispatch("delete_inspector_subject")
        -- Should not raise; project state unchanged
    end)
end)

describe("ui v2 view model — events", function()
    it("emits a notification on subscribed events", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local events = fake_events()
        local ViewModel = require("loomworks.ui.v2.view_model")
        local vm = ViewModel.new({
            workspace_provider = function() return ws end,
            events = events,
        })

        local fired = 0
        vm:subscribe(function() fired = fired + 1 end)

        events.emit("workspace_changed", ws)
        events.emit("active_set_changed", nil)

        assert.equals(2, fired)
    end)

    it("destroy removes event subscriptions", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        local events = fake_events()
        local ViewModel = require("loomworks.ui.v2.view_model")
        local vm = ViewModel.new({
            workspace_provider = function() return ws end,
            events = events,
        })

        local fired = 0
        vm:subscribe(function() fired = fired + 1 end)

        vm:destroy()
        events.emit("workspace_changed", ws)
        assert.equals(0, fired)
    end)
end)
