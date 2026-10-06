--- Plugin/binary split ratchets (ARCHITECTURE.md "Plugin/binary boundary").
--- Checked by tests/split_boundary_spec.lua. Every list here may only shrink.
---
---   edges      plugin-side or shared file -> binary-side modules it requires.
---              A new edge fails the test; so does an entry the code no longer has
---              (delete it).
---   dynamic    per file, require sites whose target can't be read statically
---              (`require(name)`, `"loomworks." .. id`). Must match exactly.
---   reach_ins  per plugin-side file, the ceiling on `core:` / `get_workspace(` /
---              `._workspace` sites. Rising fails; when it drops, lower the number.
---   interfaces_dynamic  per plugin-side file, sites naming a daemon interface at
---              run time (`iface = <expression>`, `:call(obj, <expression>, ...)`),
---              which the interface ratchet cannot check. Must match exactly;
---              each is reviewed to resolve to a versioned table the ratchet
---              does check (spec §19.20).
---
--- To regenerate after removing coupling: `nvim -l tests/split/scan.lua` prints
--- today's state in this format. Never use it to add entries without review.
return {
    edges = {
        ["lua/loomtest/runner.lua"] = {
            "loomworks.nice",
        },
        ["lua/loomworks/auto_load.lua"] = {
            "loomworks.root_finder",
        },
        ["lua/loomworks/daemon/host_binary.lua"] = {
            "boot.paths",
            "boot.pin",
        },
        ["lua/loomworks/daemon/observer.lua"] = {
            "loomworks.daemon.client",
            "loomworks.daemon.endpoint",
            "loomworks.daemon.inspect",
            "loomworks.daemon.launch",
            "loomworks.daemon.runtime",
            "loomworks.daemon.server",
        },
        ["lua/loomworks/daemon/remote_task.lua"] = {
            "loomworks.operation",
        },
        ["lua/loomworks/daemon/version.lua"] = {
            "loomworks.cache",
            "loomworks.release_notice",
            "loomworks.save_guard",
            "loomworks.user",
        },
        ["lua/loomworks/init.lua"] = {
            "loomworks.core",
            "loomworks.daemon.runtime",
            "loomworks.events",
            "loomworks.log",
            "loomworks.modules",
            "loomworks.program_fields",
            "loomworks.workspace",
        },
        ["lua/loomworks/integrations/lsp/clangd.lua"] = {
            "loomworks.exe",
            "loomworks.integrations.inventory.clangd",
        },
        ["lua/loomworks/integrations/lsp/qmlls.lua"] = {
            "loomworks.exe",
            "loomworks.integrations.inventory.qmlls",
        },
        ["lua/loomworks/overseer.lua"] = {
            "loomworks.compiler_cache",
            "loomworks.config_env",
            "loomworks.cpp_compilers",
            "loomworks.exe",
            "loomworks.future",
            "loomworks.io",
            "loomworks.modules",
            "loomworks.nice",
            "loomworks.progress",
            "loomworks.term",
            "loomworks.variables",
        },
        ["lua/loomworks/session_tracker.lua"] = {
            "loomworks.exe",
            "loomworks.future",
        },
        ["lua/loomworks/ui/deploy_editor.lua"] = {
            "loomworks.expand",
            "loomworks.paths",
        },
        ["lua/loomworks/ui/description_editor.lua"] = {
            "loomworks.configuration",
            "loomworks.configuration_set",
            "loomworks.description",
            "loomworks.profile",
            "loomworks.project",
        },
        ["lua/loomworks/ui/helpers.lua"] = {
            "loomworks.description",
        },
        ["lua/loomworks/ui/launch_editor.lua"] = {
            "loomworks.deploy",
        },
        ["lua/loomworks/ui/path_editor.lua"] = {
            "loomworks.expand",
        },
        ["lua/loomworks/ui/project_browser.lua"] = {
            "loomworks.modules",
        },
        ["lua/loomworks/ui/sections/projects.lua"] = {
            "loomworks.deploy",
            "loomworks.project",
            "loomworks.variables",
        },
        ["lua/loomworks/ui/sections/sdks.lua"] = {
            "loomworks.sdks",
        },
        ["lua/loomworks/ui/status.lua"] = {
            "loomworks.events",
            "loomworks.suggestions",
        },
        ["lua/loomworks/ui/tree.lua"] = {
            "loomworks.description",
            "loomworks.user",
            "loomworks.workspace",
        },
        ["lua/loomworks/ui/view.lua"] = {
            "loomworks.events",
        },
        ["lua/loomworks/workspace_view.lua"] = {
            "loomworks.cpp_compilers",
            "loomworks.deploy",
            "loomworks.modules",
            "loomworks.project",
            "loomworks.variables",
        },
        ["lua/lualine/components/loomworks.lua"] = {
            "loomworks.events",
        },
    },
    dynamic = {
        ["lua/loomworks/init.lua"] = 1,
        ["lua/loomworks/lsp.lua"] = 1,
    },
    reach_ins = {
        ["lua/loomtest/runner.lua"] = 1,
        ["lua/loomworks/auto_load.lua"] = 1,
        ["lua/loomworks/device_log.lua"] = 1,
        ["lua/loomworks/init.lua"] = 62,
        ["lua/loomworks/integrations/lsp/clangd.lua"] = 1,
        ["lua/loomworks/integrations/lsp/qmlls.lua"] = 1,
        ["lua/loomworks/loomtest_adapter.lua"] = 2,
        ["lua/loomworks/lsp.lua"] = 5,
        ["lua/loomworks/neotest/init.lua"] = 5,
        ["lua/loomworks/overseer.lua"] = 22,
        ["lua/loomworks/reload.lua"] = 1,
        ["lua/loomworks/session_tracker.lua"] = 1,
        ["lua/loomworks/ui/actions.lua"] = 10,
        ["lua/loomworks/ui/project_browser.lua"] = 4,
        ["lua/loomworks/ui/sections/config_sets.lua"] = 4,
        ["lua/loomworks/ui/sections/debug.lua"] = 1,
        ["lua/loomworks/ui/sections/diagnostics.lua"] = 1,
        ["lua/loomworks/ui/sections/orphaned.lua"] = 2,
        ["lua/loomworks/ui/sections/profiles.lua"] = 2,
        ["lua/loomworks/ui/sections/projects.lua"] = 6,
        ["lua/loomworks/ui/sections/sdks.lua"] = 1,
        ["lua/loomworks/ui/status.lua"] = 7,
        ["lua/loomworks/ui/tree.lua"] = 4,
        ["lua/loomworks/workspace_view.lua"] = 3,
        ["plugin/loomworks.lua"] = 1,
    },
    -- observer.lua: conn:call(M.ROOT.object, M.ROOT.iface, ...) for describe
    -- and subscribe, and the subscribe args `iface = want.iface` (want is
    -- one of M.TASKS / M.WORKSPACE): all resolve to its versioned tables.
    interfaces_dynamic = {
        ["lua/loomworks/daemon/observer.lua"] = 3,
    },
}
