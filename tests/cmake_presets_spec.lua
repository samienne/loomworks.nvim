--- Tests for cmake's CMakePresets.json fidelity.
---
--- Covers three preset behaviours the module must get right:
---   * variant is mined from `cacheVariables.CMAKE_BUILD_TYPE`;
---   * a directly-mapped preset's `binaryDir` becomes its build dir;
---   * a configuration that inherits from a `preset:*` base is warned
---     (non-blocking) because it bypasses `--preset` and loses the
---     preset's cacheVariables/binaryDir.

local cmake = require("loomworks.modules.cmake")
local Project = require("loomworks.project").Project or require("loomworks.project")
local h = require("tests.helpers")
local uv = vim.uv or vim.loop

--- Remove a directory tree.
local function rm_rf(path)
    local handle = uv.fs_scandir(path)
    if not handle then return end
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        local full = path .. "/" .. name
        if ftype == "directory" then rm_rf(full) else uv.fs_unlink(full) end
    end
    uv.fs_rmdir(path)
end

--- Write a file into the fixture dir.
local function write_file(dir, name, contents)
    local fd = assert(io.open(dir .. "/" .. name, "w"))
    fd:write(contents)
    fd:close()
end

--- Index of `flag` in a command array; nil if absent.
local function flag_index(cmd, flag)
    for i, arg in ipairs(cmd) do
        if arg == flag then return i end
    end
    return nil
end

--- Value passed to `flag` (the following arg); nil if absent.
local function flag_value(cmd, flag)
    local i = flag_index(cmd, flag)
    if i and cmd[i + 1] then return cmd[i + 1] end
    return nil
end

--- Find the task with a given loomworks action.
local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
    return nil
end

--- Resolve a task's command array by invoking its builder closure.
local function resolve_cmd(task)
    return task.builder().cmd
end

--- Build the ModuleContext a preset build sees, exactly as overseer assembles
--- it post-merge: configurations ∪ preset_configurations, keyed canonically.
--- @param dir string fixture dir
--- @param active_config string canonical config name (e.g. "preset:dev")
--- @param tool_data table|nil
--- @return table project_ctx
local function preset_ctx(dir, active_config, tool_data)
    local cmake = require("loomworks.modules.cmake")
    local info = cmake.info(dir, {})
    -- Use overseer's own merge helper so this test also covers site (A):
    -- if the merge dropped presets, config_info would be nil below.
    local configs = require("loomworks.overseer")._task_configurations(info)
    return {
        name = "App",
        path = "App",
        workspace_root = "/ws/root",
        configuration = active_config,
        configuration_key = active_config,
        configurations = configs,
        tool_data = tool_data,
        -- Directly-mapped preset build dir (part 3): its binaryDir.
        cached_build_dir = "/ws/root/out/"
            .. (active_config:gsub("^preset:", "")),
    }
end

--- A CMakePresets.json with two configure presets:
---   * `dev`: single-config Ninja, binaryDir, CMAKE_BUILD_TYPE = Release
---   * `mc` : multi-config, binaryDir, no build type
local PRESETS_JSON = [[
{
  "version": 3,
  "configurePresets": [
    { "name": "dev", "generator": "Ninja",
      "binaryDir": "${sourceDir}/out/dev",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" } },
    { "name": "mc", "generator": "Ninja Multi-Config",
      "binaryDir": "${sourceDir}/out/mc" }
  ]
}
]]

describe("cmake CMakePresets fidelity", function()
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        write_file(dir, "CMakeLists.txt", "project(App)\n")
        write_file(dir, "CMakePresets.json", PRESETS_JSON)
    end)

    after_each(function()
        rm_rf(dir)
    end)

    describe("variant from cacheVariables.CMAKE_BUILD_TYPE", function()
        it("mines the build type as the preset's variant", function()
            local info = cmake.info(dir, {})
            local dev = info.preset_configurations["preset:dev"]
            assert.is_not_nil(dev)
            assert.equals("Release", dev.variant)
        end)

        it("leaves variant nil when no CMAKE_BUILD_TYPE is declared", function()
            local info = cmake.info(dir, {})
            local mc = info.preset_configurations["preset:mc"]
            assert.is_not_nil(mc)
            assert.is_nil(mc.variant)
        end)

        it("surfaces the variant on the resulting Configuration object", function()
            local info = cmake.info(dir, {})
            local project = Project.new(h.make_mock_workspace(), "App", {
                type = "cmake", path = "App", status = "unconfigured",
                configurations = info.configurations,
                preset_configurations = info.preset_configurations,
                cached_configurations = {},
            })
            local cfg = project:get_configuration("preset:dev")
            assert.is_not_nil(cfg)
            assert.equals("Release", cfg.module_config.variant)
            -- Still not abstract: presets are self-contained (step-1 guard).
            assert.is_false(cfg:is_abstract())
        end)
    end)

    describe("directly-mapped preset binaryDir", function()
        it("uses the preset's binaryDir as the build directory", function()
            -- Mirrors Workspace:_compute_build_dir, which passes the
            -- preset Configuration's module_config as config_info.
            local info = cmake.info(dir, {})
            local project = Project.new(h.make_mock_workspace(), "App", {
                type = "cmake", path = "App", status = "unconfigured",
                configurations = info.configurations,
                preset_configurations = info.preset_configurations,
                cached_configurations = {},
            })
            local cfg = project:get_configuration("preset:dev")
            local bd = cmake.resolve_build_dir(
                "App", "preset:dev", cfg.module_config, "/ws/root", nil)
            assert.equals("/ws/root/out/dev", bd)
        end)
    end)

    describe("warn when a configuration inherits from a preset", function()
        --- Count warnings that mention both the config and the preset.
        local function inherit_warnings(warnings, cfg_name, preset_name)
            local n = 0
            for _, w in ipairs(warnings) do
                if w:find(cfg_name, 1, true) and w:find(preset_name, 1, true)
                    and w:lower():find("preset", 1, true) then
                    n = n + 1
                end
            end
            return n
        end

        it("emits exactly one non-blocking warning naming config and preset", function()
            local result = cmake.validate(dir, {
                configurations = {
                    ["my-derived"] = { inherits = "preset:dev" },
                },
            })
            assert.is_true(result.valid, "inherit-from-preset is a warning, not an error")
            assert.equals(1, inherit_warnings(result.warnings, "my-derived", "dev"),
                "one warning naming the config and preset; got: "
                .. table.concat(result.warnings, " | "))
        end)

        it("does not warn when inheriting from a variant:* configuration", function()
            local result = cmake.validate(dir, {
                configurations = {
                    ["my-debug"] = { inherits = "variant:Debug" },
                },
            })
            assert.is_true(result.valid)
            local joined = table.concat(result.warnings, " | ")
            assert.is_falsy(joined:find("inherits from preset", 1, true),
                "no preset-inherit warning for a variant base; got: " .. joined)
        end)
    end)

    describe("end-to-end task generation for a mapped preset", function()
        it("configures via `cmake --preset <bare name>`, not the manual path", function()
            local ctx = preset_ctx(dir, "preset:dev", nil)
            local tasks = cmake.tasks(ctx, "preset:dev")
            local configure = find_task(tasks, "configure")
            assert.is_not_nil(configure)
            local cmd = resolve_cmd(configure)

            -- The bare preset name — never the canonical `preset:dev`.
            assert.equals("dev", flag_value(cmd, "--preset"))
            for _, arg in ipairs(cmd) do
                assert.are_not.equals("preset:dev", arg,
                    "canonical preset key leaked into the cmake command line")
            end

            -- cmake reads the preset itself: none of the manual flags appear.
            assert.is_nil(flag_index(cmd, "-S"), "must not pass -S for a preset")
            assert.is_nil(flag_index(cmd, "-B"), "must not pass -B for a preset")
            assert.is_nil(flag_index(cmd, "-G"), "must not pass -G for a preset")
            for _, arg in ipairs(cmd) do
                assert.is_falsy(arg:find("CMAKE_BUILD_TYPE", 1, true),
                    "must not re-pass -DCMAKE_BUILD_TYPE for a preset")
            end
        end)

        it("targets the preset's binaryDir as the build dir", function()
            local ctx = preset_ctx(dir, "preset:dev", nil)
            local tasks = cmake.tasks(ctx, "preset:dev")
            local build = find_task(tasks, "build")
            assert.equals("/ws/root/out/dev", build.loomworks.build_dir)
        end)

        -- HARD RULE guard: a canonical `preset:*` string must never reach
        -- `--config`. A multi-config preset with no CMAKE_BUILD_TYPE has no
        -- variant → `--config` is omitted entirely (cmake builds its default).
        it("never passes a preset:* string to --config (multi-config, no build type)", function()
            local ctx = preset_ctx(dir, "preset:mc", { generator = "Ninja Multi-Config" })

            local build = find_task(cmake.tasks(ctx, "preset:mc"), "build")
            local bcmd = resolve_cmd(build)
            assert.is_nil(flag_index(bcmd, "--config"),
                "no --config for a multi-config preset without a build type")
            for _, arg in ipairs(bcmd) do
                assert.is_falsy(tostring(arg):find("^preset:"),
                    "canonical preset key reached the build command: " .. tostring(arg))
            end

            local clean = find_task(cmake.clean_tasks(ctx, "preset:mc"), "clean")
            local ccmd = resolve_cmd(clean)
            for _, arg in ipairs(ccmd) do
                assert.is_falsy(tostring(arg):find("^preset:"),
                    "canonical preset key reached the clean command: " .. tostring(arg))
            end
        end)

        it("passes the mined variant to --config for a multi-config preset WITH a build type", function()
            -- A multi-config preset that declares CMAKE_BUILD_TYPE has a real
            -- variant (part 2), which is the correct --config value.
            local ctx = preset_ctx(dir, "preset:mc", { generator = "Ninja Multi-Config" })
            -- Inject a build type onto the merged preset entry to simulate a
            -- multi-config preset that declares one.
            ctx.configurations["preset:mc"].variant = "Release"
            local build = find_task(cmake.tasks(ctx, "preset:mc"), "build")
            assert.equals("Release", flag_value(resolve_cmd(build), "--config"))
        end)
    end)
end)

--- CMakePresets `cacheVariables` values are EITHER a bare string OR an object
--- `{ "type": "STRING", "value": "…" }` (the form CMake's GUI/templates emit).
--- Every read must tolerate both, and cmake owns the toolchain via `--preset`.
local OBJECT_FORM_JSON = [[
{
  "version": 3,
  "configurePresets": [
    { "name": "obj", "generator": "Ninja",
      "binaryDir": "${sourceDir}/out/obj",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": { "type": "STRING", "value": "Release" },
        "CMAKE_TOOLCHAIN_FILE": { "type": "FILEPATH", "value": "${sourceDir}/tc.cmake" }
      } },
    { "name": "tcstr", "generator": "Ninja",
      "binaryDir": "${sourceDir}/out/tcstr",
      "toolchainFile": "${sourceDir}/tc.cmake" },
    { "name": "nobd", "generator": "Ninja" }
  ]
}
]]

describe("cmake preset cacheVariables shape + toolchain + binaryDir guard", function()
    local cmake = require("loomworks.modules.cmake")
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        write_file(dir, "CMakeLists.txt", "project(App)\n")
        write_file(dir, "CMakePresets.json", OBJECT_FORM_JSON)
    end)

    after_each(function()
        rm_rf(dir)
    end)

    describe("object-form cacheVariables (blocking #1)", function()
        it("reads CMAKE_BUILD_TYPE.value as a string variant, not a table", function()
            local info = cmake.info(dir, {})
            local obj = info.preset_configurations["preset:obj"]
            assert.is_not_nil(obj)
            assert.equals("string", type(obj.variant))
            assert.equals("Release", obj.variant)
        end)

        it("reads CMAKE_TOOLCHAIN_FILE.value as a string, not a table", function()
            local info = cmake.info(dir, {})
            local obj = info.preset_configurations["preset:obj"]
            assert.is_true(obj.toolchain_locked)
            assert.equals("string", type(obj.toolchain))
        end)

        it("generates tasks for an object-form preset without crashing", function()
            local ctx = preset_ctx(dir, "preset:obj", nil)
            assert.has_no.errors(function()
                cmake.tasks(ctx, "preset:obj")
            end)
        end)
    end)

    describe("toolchain does not leak into the --preset branch (blocking #2)", function()
        it("emits `cmake --preset <base>` with NO -DCMAKE_TOOLCHAIN_FILE", function()
            local ctx = preset_ctx(dir, "preset:tcstr", nil)
            local configure = find_task(cmake.tasks(ctx, "preset:tcstr"), "configure")
            local cmd = resolve_cmd(configure)
            assert.equals("tcstr", flag_value(cmd, "--preset"))
            for _, arg in ipairs(cmd) do
                assert.is_falsy(tostring(arg):find("CMAKE_TOOLCHAIN_FILE", 1, true),
                    "manual -DCMAKE_TOOLCHAIN_FILE leaked onto a --preset command: "
                    .. tostring(arg))
            end
        end)

        it("also does not leak the toolchain for an object-form preset", function()
            local ctx = preset_ctx(dir, "preset:obj", nil)
            local configure = find_task(cmake.tasks(ctx, "preset:obj"), "configure")
            local cmd = resolve_cmd(configure)
            for _, arg in ipairs(cmd) do
                assert.is_falsy(tostring(arg):find("CMAKE_TOOLCHAIN_FILE", 1, true),
                    "toolchain leaked: " .. tostring(arg))
            end
        end)
    end)

    describe("preset without binaryDir is refused (should-fix #3)", function()
        it("errors clearly instead of building a mismatched dir", function()
            local ctx = preset_ctx(dir, "preset:nobd", nil)
            local ok, err = pcall(function() cmake.tasks(ctx, "preset:nobd") end)
            assert.is_false(ok, "a preset with no binaryDir must be refused")
            assert.is_truthy(tostring(err):find("binaryDir", 1, true),
                "error must mention binaryDir; got: " .. tostring(err))
        end)
    end)
end)
