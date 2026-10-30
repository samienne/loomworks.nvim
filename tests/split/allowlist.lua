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
---   operation_sites  per file, the ceiling on editor operation call sites
---              (step 5k): in plugin-side files the overseer entry points
---              (`run_profile_action`, `run_configuration_action`, `run_*_clean`,
---              `launch_single_task`, `launch_run_task`) called through another
---              module, `tracker.start(`, `debug_mod.run(`, `:build(` /
---              `:configure(` / `:clean(` / `:launch(` and `<…>target:debug(`;
---              in binary-side files only the calls into those plugin-side
---              starters (tests/split/scan.lua has the exact rules). Step 5k
---              routes them through the daemon; rising fails; when it drops,
---              lower the number.
---   interfaces_dynamic  per plugin-side file, sites naming a daemon interface at
---              run time (`iface = <expression>`, `:call(obj, <expression>, ...)`),
---              which the interface ratchet cannot check. Must match exactly;
---              each is reviewed to resolve to a versioned table the ratchet
---              does check (spec §19.20).
---   transcripts_uncovered  `"<iface>/<v> method|signal <name>"` the plugin
---              declares it uses (its interface tables' `methods` / `signals`)
---              that the version's transcripts (spec/protocol/transcripts/)
---              do not exercise (step 5j). Must match exactly: add a
---              transcript case rather than an entry; a covered one is deleted.
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
        ["lua/loomworks/daemon/observer.lua"] = {
            "loomworks.daemon.client",
            "loomworks.daemon.inspect",
            "loomworks.daemon.runtime",
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
            "loomworks.paths",
        },
        ["lua/loomworks/ui/description_editor.lua"] = {
            "loomworks.configuration",
            "loomworks.configuration_set",
            "loomworks.description",
            "loomworks.launch_configuration",
            "loomworks.profile",
            "loomworks.project",
        },
        ["lua/loomworks/ui/helpers.lua"] = {
            "loomworks.description",
        },
        ["lua/loomworks/ui/launch_editor.lua"] = {
            "loomworks.deploy",
        },
        ["lua/loomworks/ui/project_browser.lua"] = {
            "loomworks.modules",
        },
        ["lua/loomworks/ui/sections/projects.lua"] = {
            "loomworks.deploy",
            "loomworks.project",
            "loomworks.variables",
        },
        ["lua/loomworks/ui/status.lua"] = {
            "loomworks.events",
        },
        ["lua/loomworks/ui/tree.lua"] = {
            "loomworks.description",
            "loomworks.workspace",
        },
        ["lua/loomworks/ui/view.lua"] = {
            "loomworks.events",
        },
        -- loomworks.project -> loomworks.model_commands: step 5o A1 moves the
        -- view's model writes into the host-neutral command layer (the
        -- daemon's interfaces call it too); the view keeps only the editor's
        -- `ok, err` adapters, which the status page reaches only through
        -- ui/model_calls (C0), until C2 routes the actions as calls.
        -- loomworks.deletion_plan (step 5o A2) replaces loomworks.deploy: the
        -- deletion re-checks the view's own dialogs still run moved into the
        -- deletion plans `Maintenance/1.execute_deletion` uses.
        -- (loomworks.cpp_compilers and loomworks.variables dropped: step 5o
        -- C2b2-1, the configuration editor's context is Projects/1.declaration.)
        ["lua/loomworks/workspace_view.lua"] = {
            "loomworks.deletion_plan",
            "loomworks.model_commands",
            "loomworks.modules",
        },
    },
    dynamic = {
        ["lua/loomworks/init.lua"] = 1,
        ["lua/loomworks/lsp.lua"] = 1,
    },
    reach_ins = {
        ["lua/loomtest/runner.lua"] = 1,
        -- daemon/editor_ops.lua 1 -> 0: step 6b-α A1b (operations by ids, no
        -- scope workspace).
        -- device_log.lua 1 -> 0: step 5n C2 — the dropped-lines warning
        -- goes to the view itself, not the workspace's logger.
        -- 59 -> 57, auto_load.lua / reload.lua / plugin/loomworks.lua 1 -> 0:
        -- step 6b-α A1a (`daemon` mode loads no model: the observer by root,
        -- `lw.loaded_root`, `lw.shutdown`); 57 -> 55: A1b (the facade).
        ["lua/loomworks/init.lua"] = 55,
        -- loomtest_adapter.lua 2 -> 0, neotest/init.lua 5 -> 0: step 5m part A
        -- routes the test adapters' reads through test_source.lua; its one
        -- site is the in-process source's model read (the daemon source
        -- arrives in 5m C1).
        ["lua/loomworks/test_source.lua"] = 1,
        -- lsp.lua 7 -> 0, clangd.lua / qmlls.lua 1 -> 0: step 5l part A routes
        -- the LSP layer's reads through lsp_source.lua; its one site is the
        -- in-process source's model read (the daemon source arrives in 5l C).
        ["lua/loomworks/lsp_source.lua"] = 1,
        ["lua/loomworks/overseer.lua"] = 22,
        -- actions.lua 9 -> 5, orphaned.lua 1 -> 0, tree.lua 4 -> 3: step 5o
        -- C2c-2 (the deletions and the nuke name their rows; their
        -- confirmations come from Maintenance/1).
        -- actions.lua 5 -> 1: step 5o C2d-1 (the builds, configures, cleans
        -- and rebuilds name their rows; their confirmations come from them).
        ["lua/loomworks/ui/actions.lua"] = 1,
        ["lua/loomworks/ui/project_browser.lua"] = 3,
        -- config_sets.lua 4 -> 3, diagnostics.lua 1 -> 0, orphaned.lua 2 -> 1,
        -- profiles.lua 2 -> 0, projects.lua 6 -> 5, sdks.lua 1 -> 0: step 5n
        -- part A renders the body from `view.Workspace/1` (view_state.lua);
        -- what is left are the actions' own model reads (5o's commands).
        ["lua/loomworks/ui/sections/debug.lua"] = 1,
        -- 5 -> 4: step 5o C2b2-1 (the configuration editor reads the declaration).
        -- 4 -> 1: step 5o C2b2-2 (the launch and deploy editors read the
        -- declaration, the view and expand_preview; the project's removal is left).
        -- 1 -> 0: step 6b-alpha A1a (the Add project row opens the browser at
        -- the loaded root, never the model's).
        ["lua/loomworks/ui/sections/projects.lua"] = 0,
        -- 6 -> 1: step 5n C1 — the body and its `modified` read through
        -- status_source.lua (in `daemon` mode only the daemon's
        -- view.Workspace/1); the page's other model reads (the header's root,
        -- the cursor, publish/revert until 5o) share one helper.
        ["lua/loomworks/ui/status.lua"] = 1,
        ["lua/loomworks/ui/tree.lua"] = 3,
        -- 2 -> 1: step 5o C2b2-1 (compute_edit_configuration_context removed).
        ["lua/loomworks/workspace_view.lua"] = 1,
    },
    -- Plugin-side files: the editor's own starts. Binary-side files
    -- (config_unit, launch_target, profile, target): their calls into the
    -- plugin-side starters, reached only from the editor (`LaunchTarget:launch`
    -- -> `overseer.launch_run_task`, `:debug` -> `debug_mod.run`, ...).
    -- Device steps are not counted (see tests/split/scan.lua).
    operation_sites = {
        ["lua/loomtest/runner.lua"] = 1,
        ["lua/loomworks/config_unit.lua"] = 3,
        -- 0 -> 1 each: step 6b-α A1b — the daemon-mode facade's run / debug
        -- is the session tracker's start of a LaunchRef (its preparation a
        -- Launch/1 call), and LaunchRef:launch_resolved starts the program
        -- the daemon prepared, as session_tracker's for a prepared launch.
        -- Nothing is built or run in-process for either.
        ["lua/loomworks/daemon/facade.lua"] = 1,
        ["lua/loomworks/daemon/launch_ref.lua"] = 1,
        ["lua/loomworks/init.lua"] = 4,
        -- 5 -> 4: step 5k C2 — LaunchTarget:debug resolves one spec for
        -- run and debug (§8.9.6): one nvim-dap start, not one per kind.
        ["lua/loomworks/launch_target.lua"] = 4,
        -- 0 -> 1: step 5m C2 — the debugger start of a test debug the daemon
        -- prepared (Tests/1.prepare_debug; the program is the editor's,
        -- §19.16 "Tests" Debug): one nvim-dap start for the launch and its
        -- attaches, as session_tracker's for a prepared launch. Nothing is
        -- built or run in-process for it.
        ["lua/loomworks/loomtest_adapter.lua"] = 1,
        ["lua/loomworks/profile.lua"] = 3,
        ["lua/loomworks/session_tracker.lua"] = 5,
        ["lua/loomworks/target.lua"] = 3,
        -- ui/actions.lua 12 -> 0 (deleted), ui/model_calls.lua 0 -> 6: step 5o
        -- C2d-1 moves the status page's in-process builds, configures and
        -- cleans (the `in-process` mode's bodies of Build/1.build / configure
        -- / clean) to ui/model_calls.lua; in `daemon` mode they are only calls
        -- by row id.
        ["lua/loomworks/ui/model_calls.lua"] = 6,
    },
    -- observer.lua: conn:call(M.ROOT.object, M.ROOT.iface, ...) for describe
    -- and subscribe, the subscribe args `iface = want.iface` (want is one of
    -- M.FEATURES), and the views' `get` after a seq gap,
    -- conn:call(want.object, want.iface, ...) (want is one of M.VIEWS, step
    -- 5j), and the four CALLS of step 5k (the editor's operations and their
    -- cancel), conn:call(M.BUILD.object, M.BUILD.iface, ...) x3 and
    -- conn:call(M.TASKS.object, M.TASKS.iface, ...): all resolve to its
    -- versioned tables.
    -- 8 -> 12: step 5k C2 adds four CALLS, each naming its method literally
    -- (the method guard needs a literal): conn:call(M.LAUNCH.object,
    -- M.LAUNCH.iface, ...) for prepare_run / prepare_debug and
    -- conn:call(M.DEBUG.object, M.DEBUG.iface, ...) for adapters /
    -- set_adapter — both versioned tables (Launch/1, DebugConfig/1).
    -- 12 -> 14: step 5l part C adds two CALLS, each naming its method
    -- literally: conn:call(M.LSP.object, M.LSP.iface, ...) for get /
    -- set_option — the versioned table LspConfig/1.
    -- 14 -> 15: step 5m C1 adds one CALL naming its method literally:
    -- conn:call(M.TESTS.object, M.TESTS.iface, ...) for discover — the
    -- versioned table Tests/1 (the tests view's `get` goes through M.VIEWS).
    -- 15 -> 19: step 5m C2 adds four CALLS naming their methods literally:
    -- conn:call(M.TESTS.object, M.TESTS.iface, ...) for run_cases,
    -- prepare_debug (the call `prepare_test_debug`), collect and result —
    -- the versioned table Tests/1.
    -- 19 -> 21: step 5t C adds two CALLS naming their methods literally:
    -- conn:call(M.LAUNCH.object, M.LAUNCH.iface, ...) for build (the call
    -- `launch_build`) and conn:call(M.TASKS.object, M.TASKS.iface, ...) for
    -- list (the steps re-read after a seq gap) — Launch/1 and Tasks/1.
    -- 21 -> 28: step 5n C2 adds seven CALLS naming their methods literally:
    -- conn:call(M.DEVICES.object, M.DEVICES.iface, ...) for list, scan,
    -- install, launch and stop (the calls `device_<method>`) and
    -- conn:call(M.PROFILES.object, M.PROFILES.iface, ...) for set_device and
    -- clear_device — the versioned tables Devices/1 and Profiles/1.
    -- 28 -> 32: step 5n C3 (the device log) adds one CALL naming its method
    -- literally, conn:call(M.LAUNCH.object, M.LAUNCH.iface, ...) for
    -- device_log; the `log` subscription's Root subscribe and unsubscribe,
    -- conn:call(M.ROOT.object, M.ROOT.iface, ...) x2, whose subscribe names
    -- { object = M.LAUNCH.object, iface = M.LAUNCH.iface, v = M.LAUNCH.v };
    -- and _on_message's match of the `log` signal on M.LAUNCH.iface — the
    -- versioned tables Root/1 and Launch/1.
    -- 32 -> 50: step 5o C2a adds seventeen CALLS naming their methods
    -- literally, conn:call(M.WORKSPACE.object, M.WORKSPACE.iface, ...) x8,
    -- conn:call(M.PROFILES.object, M.PROFILES.iface, ...) x5 and
    -- conn:call(M.CONFIG_SETS.object, M.CONFIG_SETS.iface, ...) x4, and the
    -- qualified names of METHOD_IFACE built from `want.iface` (want one of
    -- M.WORKSPACE, M.PROFILES, M.CONFIG_SETS) — the versioned tables
    -- Workspace/1, Profiles/1 and ConfigSets/1.
    -- 50 -> 58: step 5o C2b adds eight CALLS naming their methods literally,
    -- conn:call(M.PROJECTS.object, M.PROJECTS.iface, ...) x8 (candidates,
    -- add, declaration, configuration_remove, launch_remove, variable_save,
    -- variable_remove, type_config_set) — the versioned table Projects/1.
    -- 58 -> 59: step 5o C2b2-1 adds configuration_save,
    -- conn:call(M.PROJECTS.object, M.PROJECTS.iface, ...) — Projects/1.
    -- 59 -> 62: step 5o C2b2-2 adds launch_save, deploy_save and
    -- expand_preview, conn:call(M.PROJECTS.object, M.PROJECTS.iface, ...)
    -- x3 — Projects/1.
    -- 62 -> 66: step 5o C2c-1 adds four CALLS naming their methods
    -- literally, conn:call(M.TOOLCHAINS.object, M.TOOLCHAINS.iface, ...) for
    -- rescan and conn:call(M.SDKS.object, M.SDKS.iface, ...) x3 (detect, add,
    -- remove) — the versioned tables Toolchains/1 and Sdks/1.
    interfaces_dynamic = {
    -- 66 -> 68: step 5o C2c-2 adds two CALLS naming their methods literally,
    -- conn:call(M.MAINTENANCE.object, M.MAINTENANCE.iface, ...) for
    -- execute_deletion and nuke — the versioned table Maintenance/1.
    -- 68 -> 69: step 5o C2d-2 adds Projects/1.unit_options,
    -- conn:call(M.PROJECTS.object, M.PROJECTS.iface, ...) — the versioned
    -- table Projects/1.
    -- 69 -> 71: step 6b-alpha (WP-C) adds Launch/1.targets,
    -- conn:call(M.LAUNCH.object, M.LAUNCH.iface, ...), and
    -- Profiles/1.set_default_target, conn:call(M.PROFILES.object,
    -- M.PROFILES.iface, ...) — the versioned tables Launch/1 and Profiles/1.
    -- 71 -> 72: WP-B T3 adds DebugConfig/1.known_languages (the launch
    -- editor's "Add debug language"), conn:call(M.DEBUG.object,
    -- M.DEBUG.iface, ...) — the versioned table DebugConfig/1.
        ["lua/loomworks/daemon/observer.lua"] = 72,
    },
    -- Root's two connection-wide signals, handled by the observer since step
    -- 5g.3 but in no transcript: `objects_changed` has no core trigger (core
    -- objects are mounted before any load; a module mounting objects sends
    -- it), `retiring` needs the daemon retired mid-case (a `retire` control
    -- frame), after which it exits once idle.
    transcripts_uncovered = {
        "loomworks.Root/1 signal objects_changed",
        "loomworks.Root/1 signal retiring",
    },
}
