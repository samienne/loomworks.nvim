--- Integration tests for cmake's multi-config generator handling.
---
--- Multi-config generators (Visual Studio, Ninja Multi-Config) only
--- understand the underlying variant name (Debug, Release, ...) at
--- the `--config` flag. A user-declared configuration like
--- `debug-with-addon` that inherits Debug must be passed as
--- `--config Debug`, otherwise msbuild rejects the combination
--- ("This project doesn't contain the Configuration and Platform
--- combination of debug-with-addon|x64..."). The test exercises the
--- task-spec construction directly — we don't need to invoke
--- msbuild or cmake to verify the wiring. Mocking the build tool
--- would just be testing the mock; reading the task's resolved
--- command is the integration that actually matters.

local cmake = require("loomworks.modules.cmake")

--- Find the index of `flag` in a command array; returns nil if absent.
--- @param cmd string[]
--- @param flag string
--- @return integer|nil
local function flag_index(cmd, flag)
    for i, arg in ipairs(cmd) do
        if arg == flag then return i end
    end
    return nil
end

--- Find the value passed to a flag (the arg following it) in a command.
--- @param cmd string[]
--- @param flag string
--- @return string|nil
local function flag_value(cmd, flag)
    local i = flag_index(cmd, flag)
    if i and cmd[i + 1] then return cmd[i + 1] end
    return nil
end

--- Find the build/clean task in a list returned by M.tasks/clean_tasks.
--- @param tasks table[]
--- @param action string
--- @return table|nil
local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
    return nil
end

--- Resolve a task's command array by invoking its builder closure.
--- @param task table
--- @return string[]
local function resolve_cmd(task)
    return task.builder().cmd
end

local function vs_project_ctx()
    return {
        name = "App",
        path = "App",
        workspace_root = "/fake/root",
        configurations = {
            ["debug-with-addon"] = {
                variant = "Debug",
                generator = "Visual Studio 17 2022",
            },
            ["release-tuned"] = {
                variant = "Release",
                generator = "Visual Studio 17 2022",
            },
            ["Debug"] = {
                variant = "Debug",
                generator = "Visual Studio 17 2022",
            },
        },
        tool_data = { generator = "Visual Studio 17 2022" },
        cached_build_dir = "/fake/root/App/build",
    }
end

local function ninja_project_ctx()
    -- Single-config baseline: --config must NOT appear at all.
    return {
        name = "App",
        path = "App",
        workspace_root = "/fake/root",
        configurations = {
            ["my-debug"] = { variant = "Debug", generator = "Ninja" },
        },
        tool_data = { generator = "Ninja" },
        cached_build_dir = "/fake/root/App/build",
    }
end

describe("cmake multi-config --config wiring", function()

    describe("M.tasks build (Visual Studio generator)", function()
        it("passes the inherited variant — not the user config name", function()
            -- The bug: user picks `debug-with-addon` (inherits Debug);
            -- old code passed `--config debug-with-addon` which msvc
            -- rejects with "This project doesn't contain the
            -- Configuration and Platform combination of
            -- debug-with-addon|x64...".
            local tasks = cmake.tasks(vs_project_ctx(), "debug-with-addon")
            local build = find_task(tasks, "build")
            assert.is_not_nil(build)
            local cmd = resolve_cmd(build)
            assert.equals("Debug", flag_value(cmd, "--config"))
            -- And explicitly NOT the user-facing config name:
            for _, arg in ipairs(cmd) do
                assert.are_not.equals("debug-with-addon", arg,
                    "user config name leaked into msbuild command line")
            end
        end)

        it("preserves the user config name in the task display name", function()
            -- The display name is the user's identity — unaffected by
            -- variant resolution. They selected `debug-with-addon`,
            -- they should see it in the overseer task list.
            local tasks = cmake.tasks(vs_project_ctx(), "debug-with-addon")
            local build = find_task(tasks, "build")
            assert.is_not_nil(build)
            assert.equals("App: build debug-with-addon", build.name)
        end)

        it("uses the user config name as configuration_key (cache identity)", function()
            local tasks = cmake.tasks(vs_project_ctx(), "debug-with-addon")
            local build = find_task(tasks, "build")
            assert.equals("debug-with-addon", build.loomworks.configuration_key)
        end)

        it("works for Release-inheriting configs too", function()
            local tasks = cmake.tasks(vs_project_ctx(), "release-tuned")
            local build = find_task(tasks, "build")
            local cmd = resolve_cmd(build)
            assert.equals("Release", flag_value(cmd, "--config"))
        end)

        it("falls back to active_config when no variant is set", function()
            -- For configs whose name *is* a real variant (Debug,
            -- Release directly), the lookup pulls variant from the
            -- definition. Either way the resulting --config arg is a
            -- valid msvc variant.
            local tasks = cmake.tasks(vs_project_ctx(), "Debug")
            local build = find_task(tasks, "build")
            local cmd = resolve_cmd(build)
            assert.equals("Debug", flag_value(cmd, "--config"))
        end)
    end)

    describe("M.clean_tasks (Visual Studio generator)", function()
        it("passes the variant on --config, not the user name", function()
            local tasks = cmake.clean_tasks(vs_project_ctx(), "debug-with-addon")
            local clean = find_task(tasks, "clean")
            assert.is_not_nil(clean)
            local cmd = resolve_cmd(clean)
            assert.equals("Debug", flag_value(cmd, "--config"))
        end)

        it("display name still uses user config name", function()
            local tasks = cmake.clean_tasks(vs_project_ctx(), "debug-with-addon")
            local clean = find_task(tasks, "clean")
            assert.equals("App: clean debug-with-addon", clean.name)
        end)
    end)

    describe("M.build_target_task (Visual Studio generator)", function()
        it("passes the variant on --config, not the user name", function()
            local ctx = vs_project_ctx()
            ctx.configuration = "debug-with-addon"
            local task = cmake.build_target_task(ctx, "MyTarget")
            local cmd = resolve_cmd(task)
            assert.equals("Debug", flag_value(cmd, "--config"))
            assert.equals("MyTarget", flag_value(cmd, "--target"))
        end)
    end)

    describe("Ninja (single-config) baseline", function()
        it("does not emit --config at all on build", function()
            -- Single-config generators don't take --config. The
            -- variant goes to -DCMAKE_BUILD_TYPE at configure time;
            -- the build invocation has no per-variant flag.
            local tasks = cmake.tasks(ninja_project_ctx(), "my-debug")
            local build = find_task(tasks, "build")
            local cmd = resolve_cmd(build)
            assert.is_nil(flag_index(cmd, "--config"),
                "Ninja build must not pass --config")
        end)

        it("does not emit --config at all on clean", function()
            local tasks = cmake.clean_tasks(ninja_project_ctx(), "my-debug")
            local clean = find_task(tasks, "clean")
            local cmd = resolve_cmd(clean)
            assert.is_nil(flag_index(cmd, "--config"),
                "Ninja clean must not pass --config")
        end)
    end)
end)
