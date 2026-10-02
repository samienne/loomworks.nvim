--- `lw build --target` operand resolution (headless §16.4 *Naming a build
--- target*).
---
--- The bug (LumeEditor field report): `lw target` lists an executable as
--- `LumeEditor:LumeEditor`, but `lw build <profile> --target
--- LumeEditor:LumeEditor` handed the qualified operand verbatim to cmake/ninja
--- ("ninja: error: unknown target 'LumeEditor:LumeEditor'"), then lw said the
--- target was not among LumeEditor's known targets. `--target` now accepts the
--- form `lw target` prints (and an unambiguous bare name), resolves it against
--- the known target lists BEFORE anything runs, and gives the build tool the
--- bare name in that project's build directory only.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local function has_seq(cmd, seq)
    for i = 1, #cmd - #seq + 1 do
        local ok = true
        for j = 1, #seq do
            if cmd[i + j - 1] ~= seq[j] then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

local TOOL = { key = "ninja-gcc-13", data = {
    compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake",
} }

--- Two cmake projects App + Lib in profile `debug`, in a real temp root.
local function make_core()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    vim.fn.mkdir(root .. "/Lib", "p")
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = {
                App = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
                Lib = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
            configuration_sets = { debug = { App = "Debug", Lib = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = TOOL.key, data = TOOL.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = TOOL.key, tool_data = TOOL.data, tool_label = TOOL.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    return ws, ws._profiles[1], root
end

--- The profile's unit for project `key`.
local function unit_of(profile, key)
    for _, pp in ipairs(profile:projects()) do
        if pp._project and pp._project.key == key then return pp._config_unit end
    end
end

--- Make a unit look configured on this machine with the given target list
--- (no configure needed, so its list is known).
local function configured(unit, targets)
    unit.configure_reason = function() return nil end
    unit:set_targets(targets)
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, res = pcall(fn)
    loomworks.get_workspace = orig
    if not ok then error(res, 0) end
    return res
end

--- `lw <args>` through cmd_build with the spawn stubbed. Returns the spawned
--- steps, the exit code (nil = success) and stderr.
local function run_build(ws, args, spawn_code)
    local cli = require("loomworks.cli")
    local spawned, err_buf = {}, {}
    local orig_spawn, orig_write, orig_stderr, orig_exit = cli._run_spec, io.write, io.stderr, os.exit
    local exit_code
    cli._run_spec = function(step)
        spawned[#spawned + 1] = step
        return spawn_code and spawn_code(step) or 0
    end
    io.write = function() end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    os.exit = function(c) exit_code = c or 0; error({ __exit = true }, 0) end
    local ok, err = pcall(function()
        with_ws(ws, function() return cli.cmd_build(ws, args) end)
    end)
    cli._run_spec, io.write, io.stderr, os.exit = orig_spawn, orig_write, orig_stderr, orig_exit
    if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
    return spawned, exit_code, table.concat(err_buf)
end

local function build_steps(spawned)
    local out = {}
    for _, s in ipairs(spawned) do if s.kind == "build" then out[#out + 1] = s end end
    return out
end

describe("lw build --target: operand resolution (§16.4)", function()
    local root, ws, profile
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end
        ws, profile, root = make_core()
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    local function both_known()
        configured(unit_of(profile, "App"), {
            AppRunner = { type = "executable" }, Common = { type = "static_library" } })
        configured(unit_of(profile, "Lib"), {
            LibTool = { type = "executable" }, Common = { type = "static_library" } })
    end

    it("the project-qualified form `lw target` prints builds that target in that project only", function()
        both_known()
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "App:AppRunner" })
        assert.is_nil(code, stderr)
        local b = build_steps(spawned)
        assert.equals(1, #b, "only App is built")
        assert.equals(unit_of(profile, "App"), b[1].unit)
        assert.is_true(has_seq(b[1].cmd, { "--target", "AppRunner" }), table.concat(b[1].cmd, " "))
        for _, a in ipairs(b[1].cmd) do assert.not_equals("App:AppRunner", a) end
    end)

    it("an unambiguous bare name builds in the one project that has it", function()
        both_known()
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "LibTool" })
        assert.is_nil(code, stderr)
        local b = build_steps(spawned)
        assert.equals(1, #b)
        assert.equals(unit_of(profile, "Lib"), b[1].unit)
        assert.is_true(has_seq(b[1].cmd, { "--target", "LibTool" }))
    end)

    it("an ambiguous bare name is refused before anything runs, listing the qualified candidates", function()
        both_known()
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "Common" })
        assert.equals(1, code)
        assert.equals(0, #spawned)
        assert.truthy(stderr:find("App:Common", 1, true), stderr)
        assert.truthy(stderr:find("Lib:Common", 1, true), stderr)
        assert.truthy(stderr:find("ambiguous", 1, true), stderr)
    end)

    it("an unknown bare name is lw's refusal with close matches; the build tool never runs", function()
        both_known()
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "AppRuner" })
        assert.equals(1, code)
        assert.equals(0, #spawned, "the build tool must not run")
        assert.truthy(stderr:find("did you mean 'App:AppRunner'", 1, true), stderr)
        assert.falsy(stderr:find("unknown target", 1, true), stderr)
    end)

    it("an unknown qualified target is refused up front, naming close matches in that project", function()
        both_known()
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "App:AppRuner" })
        assert.equals(1, code)
        assert.equals(0, #spawned)
        assert.truthy(stderr:find("not among App's known targets", 1, true), stderr)
        assert.truthy(stderr:find("did you mean 'AppRunner'", 1, true), stderr)
    end)

    it("several operands may select different projects", function()
        both_known()
        local spawned, code, stderr = run_build(ws, { "build", profile.key,
            "--target", "AppRunner", "--target", "Lib:Common" })
        assert.is_nil(code, stderr)
        local b = build_steps(spawned)
        assert.equals(2, #b)
        for _, s in ipairs(b) do
            if s.unit == unit_of(profile, "App") then
                assert.is_true(has_seq(s.cmd, { "--target", "AppRunner" }), table.concat(s.cmd, " "))
            else
                assert.is_true(has_seq(s.cmd, { "--target", "Common" }), table.concat(s.cmd, " "))
                assert.is_false(has_seq(s.cmd, { "AppRunner" }))
            end
        end
    end)

    it("a prefix that is no project of the profile keeps the operand whole (module syntax)", function()
        configured(unit_of(profile, "App"), { ["tool:exe"] = { type = "executable" } })
        configured(unit_of(profile, "Lib"), { Other = { type = "executable" } })
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "tool:exe" })
        assert.is_nil(code, stderr)
        local b = build_steps(spawned)
        assert.equals(1, #b)
        assert.is_true(has_seq(b[1].cmd, { "--target", "tool:exe" }))
    end)

    it("a bare name no known list has goes to the projects whose list is not known yet", function()
        configured(unit_of(profile, "App"), { AppRunner = { type = "executable" } })
        -- Lib is unconfigured: its target list is not known, its build tool decides.
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target", "Gen" })
        assert.is_nil(code, stderr)
        local b = build_steps(spawned)
        assert.equals(1, #b)
        assert.equals(unit_of(profile, "Lib"), b[1].unit)
        assert.is_true(has_seq(b[1].cmd, { "--target", "Gen" }))
    end)
end)
