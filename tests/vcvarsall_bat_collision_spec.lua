--- Regression: MSVC+Ninja vcvarsall .bat filename must be distinct per
--- wrapped command.
---
--- The bug: write_vcvarsall_bat wrote a FIXED name (loomworks_build.bat)
--- into the build dir as a side effect of wrapping a command. Both the
--- configure and build task builders wrap into the same build dir, and the
--- orchestrator materializes ALL builders before any task runs — so the
--- build builder's write clobbered the configure builder's .bat. Both
--- tasks' commands became `cmd /C .../loomworks_build.bat` holding the
--- BUILD command, so the "configure" task ran `cmake --build <dir>` against
--- a directory with no CMakeCache.txt → "could not load cache" → configure
--- failed with exit 1.
---
--- wrap_cmd fires for `kit.vcvarsall and generator == "Ninja"` and is NOT
--- OS-gated, so this reproduces on any platform by passing a kit table with
--- vcvarsall set. We only need a real temp build dir (the .bat is written to
--- disk) — no real MSVC or cmake.

local cmake = require("loomworks.modules.cmake")

--- @param tasks table[]
--- @param action string
--- @return table|nil
local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
    return nil
end

--- Read a file's full contents.
local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

describe("cmake vcvarsall .bat filename (MSVC+Ninja)", function()
    local root, build_dir

    before_each(function()
        root = vim.fn.tempname()
        build_dir = root .. "/build"
        vim.fn.mkdir(build_dir, "p")
    end)

    --- Project ctx driving the single-config Ninja + MSVC repro path.
    local function ctx()
        return {
            name = "App",
            path = "App",
            workspace_root = root,
            configurations = {
                ["my-debug"] = { variant = "Debug", generator = "Ninja" },
            },
            -- vcvarsall present → wrap_cmd wraps into a .bat; ninja-msvc kit.
            tool_data = {
                generator = "Ninja",
                vcvarsall = "C:/VS/vcvarsall.bat",
                arch = "x64",
            },
            cached_build_dir = build_dir,
        }
    end

    it("gives configure and build distinct .bat files, and configure keeps its command", function()
        local tasks = cmake.tasks(ctx(), "my-debug")
        local configure = find_task(tasks, "configure")
        local build = find_task(tasks, "build")
        assert.is_not_nil(configure)
        assert.is_not_nil(build)

        -- Materialize BOTH builders before "executing" anything, in the
        -- order the orchestrator would. Each write happens here.
        local configure_cmd = configure.builder().cmd
        local build_cmd = build.builder().cmd

        -- Both are wrapped: { "cmd", "/C", <bat_path> }
        assert.equals("cmd", configure_cmd[1])
        assert.equals("cmd", build_cmd[1])
        local configure_bat = configure_cmd[3]
        local build_bat = build_cmd[3]
        assert.is_not_nil(configure_bat)
        assert.is_not_nil(build_bat)

        -- (1) Distinct filenames — before the fix both were loomworks_build.bat.
        assert.are_not.equals(configure_bat, build_bat,
            "configure and build must not share a .bat filename")

        -- (2) The file the CONFIGURE command points at must still hold the
        -- CONFIGURE command after the build builder has also run. Before the
        -- fix it held `cmake --build <dir>` → "could not load cache".
        local contents = read_all(configure_bat)
        assert.is_not_nil(contents)
        assert.is_truthy(contents:find("-S", 1, true) and contents:find("-B", 1, true),
            "configure .bat must contain the configure command (cmake -G ... -S -B), got:\n" .. contents)
        assert.is_nil(contents:find("--build", 1, true),
            "configure .bat was clobbered by the build command:\n" .. contents)
    end)

    it("gives clean its own distinct .bat file too", function()
        local build_tasks = cmake.tasks(ctx(), "my-debug")
        local configure = find_task(build_tasks, "configure")
        local build = find_task(build_tasks, "build")
        local configure_bat = configure.builder().cmd[3]
        local build_bat = build.builder().cmd[3]

        local clean_tasks = cmake.clean_tasks(ctx(), "my-debug")
        local clean = find_task(clean_tasks, "clean")
        assert.is_not_nil(clean)
        local clean_bat = clean.builder().cmd[3]
        assert.is_not_nil(clean_bat)

        assert.are_not.equals(clean_bat, configure_bat)
        assert.are_not.equals(clean_bat, build_bat)

        local contents = read_all(clean_bat)
        assert.is_truthy(contents:find("--target", 1, true) and contents:find("clean", 1, true),
            "clean .bat must contain the clean command:\n" .. contents)
    end)
end)
