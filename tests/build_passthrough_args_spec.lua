--- Build-tool arguments and targets (headless §16.4 *Build arguments and
--- targets*, core §8.1 `build_args` / `build_targets`).
---
--- The bug: `lw build <profile> -- --target AppRunner` appended the forwarded
--- args to the build step's FINAL command. For an MSVC-style kit with the Ninja
--- generator that command runs a vcvarsall batch through cmd.exe (named by the
--- LOOMWORKS_VCVARS_BAT env var, cmake spec §14) — the real
--- `cmake --build …` line lives inside the batch file — so the args became
--- ignored batch parameters and the default target was built instead.
--- Forwarded args (and `--target`) now reach the module, which puts them on its
--- native build invocation BEFORE wrapping.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local meson = require("loomworks.modules.meson")
local shell = require("loomworks.modules.shell")
local typescript = require("loomworks.modules.typescript")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")

local orig_lookup = cpp.lookup_path

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

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

--- cmake project App/Debug + profile `debug` on `tool`, in a real temp root.
local function make_core(tool)
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { cmake = { configurations = { Debug = { variant = "Debug" } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = tool.key, data = tool.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = tool.key, tool_data = tool.data, tool_label = tool.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    return ws, ws._profiles[1], root
end

--- A stand-in vcvarsall.bat (msvc.check_vcvarsall needs an existing file);
--- nothing runs it.
local function fake_vcvarsall(dir)
    vim.fn.mkdir(dir .. "/VS", "p")
    local p = (dir .. "/VS/vcvarsall.bat"):gsub("\\", "/")
    vim.fn.writefile({ "@echo off" }, p)
    return p
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

--- Run `lw <args>` through cmd_build with the spawn stubbed. Returns the
--- spawned steps, the exit code (nil = success) and stderr.
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

local function build_step(spawned)
    for _, s in ipairs(spawned) do if s.kind == "build" then return s end end
end

describe("lw build: forwarded build-tool args reach the build tool", function()
    local root
    before_each(function()
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
        cpp.lookup_path = function() return nil end -- no cache tools on "PATH"
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    local function msvc_core()
        local vs_dir = (vim.fn.tempname():gsub("\\", "/"))
        local tool = { key = "ninja-msvc-17", data = {
            compiler_id = "msvc-17", generator = "Ninja", cmake_path = "/fake/cmake",
            vcvarsall = fake_vcvarsall(vs_dir), arch = "x64",
        } }
        local ws, profile, r = make_core(tool)
        return ws, profile, r, vs_dir
    end

    it("MSVC + Ninja (vcvars-wrapped): `-- --target AppRunner` lands inside the .bat", function()
        local ws, profile, r, vs = msvc_core()
        root = r
        local spawned = run_build(ws, { "build", profile.key, "--", "--target", "AppRunner" })
        local b = build_step(spawned)
        assert.is_not_nil(b)
        assert.equals("cmd", b.cmd[1])
        assert.same({ "cmd", "/d", "/v:on", "/c", "!LOOMWORKS_VCVARS_BAT!" }, b.cmd,
            "nothing may be appended after the wrapped batch: " .. table.concat(b.cmd, " "))
        local bat = read_all(b.env.LOOMWORKS_VCVARS_BAT)
        assert.is_not_nil(bat)
        assert.is_truthy(bat:find('"--build"', 1, true), bat)
        assert.is_truthy(bat:find('"--target" "AppRunner"', 1, true),
            "the batch must run cmake --build with the forwarded args:\n" .. bat)
        vim.fn.delete(vs, "rf")
    end)

    it("MSVC + Ninja: `--target AppRunner` (repeatable) maps to cmake --build --target", function()
        local ws, profile, r, vs = msvc_core()
        root = r
        local spawned = run_build(ws, { "build", profile.key, "--target", "AppRunner",
            "--target", "Runtime" })
        local bat = read_all(build_step(spawned).env.LOOMWORKS_VCVARS_BAT)
        assert.is_truthy(bat:find('"--target" "AppRunner" "Runtime"', 1, true), bat)
        vim.fn.delete(vs, "rf")
    end)

    it("MSVC + Ninja: batch-unsafe args are escaped (%) or refused (\"), never dropped", function()
        local ws, profile, r, vs = msvc_core()
        root = r
        local spawned = run_build(ws, { "build", profile.key, "--", "-DX=100%" })
        local bat = read_all(build_step(spawned).env.LOOMWORKS_VCVARS_BAT)
        assert.is_truthy(bat:find('"-DX=100%%"', 1, true), bat)

        local spawned2, code, stderr = run_build(ws, { "build", profile.key, "--", 'a"b' })
        assert.equals(1, code)
        assert.is_nil(build_step(spawned2), "a refused arg must not build without it")
        assert.matches("quote or line break", stderr)
        vim.fn.delete(vs, "rf")
    end)

    it("GCC + Ninja (unwrapped): args and --target go on cmake --build", function()
        local ws, profile, r = make_core({ key = "ninja-gcc-13", data = {
            compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake",
        } })
        root = r
        local b = build_step(run_build(ws, { "build", profile.key, "--", "--target", "AppRunner" }))
        assert.equals("/fake/cmake", b.cmd[1])
        assert.is_true(has_seq(b.cmd, { "--build" }))
        assert.is_true(has_seq(b.cmd, { "--target", "AppRunner" }))

        local b2 = build_step(run_build(ws, { "build", profile.key, "--target", "AppRunner",
            "--", "-j", "4" }))
        assert.is_true(has_seq(b2.cmd, { "--target", "AppRunner", "-j", "4" }),
            table.concat(b2.cmd, " "))
    end)

    it("`--target` needs a name", function()
        local ws, profile, r = make_core({ key = "ninja-gcc-13", data = {
            compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake",
        } })
        root = r
        local spawned, code, stderr = run_build(ws, { "build", profile.key, "--target" })
        assert.equals(1, code)
        assert.equals(0, #spawned)
        assert.matches("%-%-target needs", stderr)
    end)

    it("a failed --target build names close matches from the known targets", function()
        local ws, profile, r = make_core({ key = "ninja-gcc-13", data = {
            compiler_id = "gcc-13", generator = "Ninja", cmake_path = "/fake/cmake",
        } })
        root = r
        local unit = profile:projects()[1]._config_unit
        unit:set_targets({ AppRunner = { type = "executable" }, Runtime = { type = "shared_library" } })
        local _, code, stderr = run_build(ws, { "build", profile.key, "--target", "AppRuner" },
            function(step) return step.kind == "build" and 1 or 0 end)
        assert.equals(1, code)
        assert.matches("AppRuner", stderr)
        assert.matches("did you mean 'AppRunner'", stderr)
    end)
end)

describe("module build_args / build_targets", function()
    local root, vcvarsall
    before_each(function()
        root = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(root .. "/build", "p")
        vcvarsall = fake_vcvarsall(root)
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    local function build_task(tasks)
        for _, t in ipairs(tasks) do
            if t.loomworks and t.loomworks.action == "build" then return t end
        end
    end

    it("cmake preset + MSVC Ninja: args and targets are inside the .bat", function()
        local t = build_task(cmake.tasks({
            name = "App", path = "App", workspace_root = root,
            configurations = { ["preset:dev"] = {
                prefix = "preset", base_name = "dev", from_preset = true,
                generator = "Ninja", binary_dir = root .. "/build", variant = "Debug",
            } },
            tool_data = { generator = "Ninja", vcvarsall = vcvarsall, arch = "x64" },
            cached_build_dir = root .. "/build",
            build_args = { "-j", "2" }, build_targets = { "AppRunner" },
        }, "preset:dev"))
        assert.is_true(t.loomworks.applied_build_args)
        assert.is_true(t.loomworks.applied_build_targets)
        local spec = t.builder()
        assert.same({ "cmd", "/d", "/v:on", "/c", "!LOOMWORKS_VCVARS_BAT!" }, spec.cmd)
        local bat = read_all(spec.env.LOOMWORKS_VCVARS_BAT)
        assert.is_truthy(bat:find('"--target" "AppRunner" "-j" "2"', 1, true), bat)
    end)

    it("cmake multi-config: --target / args follow --config", function()
        local t = build_task(cmake.tasks({
            name = "App", path = "App", workspace_root = root,
            configurations = { Debug = { variant = "Debug" } },
            tool_data = { generator = "Ninja Multi-Config", cmake_path = "cmake" },
            cached_build_dir = root .. "/build",
            build_args = { "-v" }, build_targets = { "A", "B" },
        }, "Debug"))
        local cmd = t.builder().cmd
        assert.is_true(has_seq(cmd, { "--config", "Debug", "--target", "A", "B", "-v" }),
            table.concat(cmd, " "))
    end)

    it("meson: targets are positional names, args follow", function()
        local t = build_task(meson.tasks({
            name = "App", path = "app", workspace_root = root,
            tool_data = { meson = { "/usr/bin/meson" } },
            configurations = { Debug = { buildtype = "debug" } }, env = {},
            cached_build_dir = root .. "/build",
            build_args = { "-j", "4" }, build_targets = { "AppRunner", "Runtime" },
        }, "Debug"))
        assert.is_true(t.loomworks.applied_build_args)
        assert.is_true(t.loomworks.applied_build_targets)
        assert.is_true(has_seq(t.builder().cmd,
            { "compile", "-C", root .. "/build", "AppRunner", "Runtime", "-j", "4" }))
    end)

    it("shell: args append to build_cmd; targets unsupported", function()
        local t = build_task(shell.tasks({
            name = "App", path = "app", workspace_root = root,
            type_config = {
                build_dir = "${workspace_root}/out", build_cmd = { "./build.sh", "--fast" },
            },
            configurations = { default = { variant = "default" } }, env = {},
            build_args = { "-k" },
        }, "default"))
        assert.is_true(t.loomworks.applied_build_args)
        assert.is_nil(t.loomworks.applied_build_targets)
        assert.same({ "./build.sh", "--fast", "-k" }, t.builder().cmd)
    end)

    it("typescript: args are checked like every npm argument, before the cmd /c wrap", function()
        vim.fn.mkdir(root .. "/app", "p")
        vim.fn.writefile({ '{"scripts":{"build":"tsc"}}' }, root .. "/app/package.json")
        local ctx = {
            name = "App", path = "app", workspace_root = root, configurations = {},
            build_args = { "--verbose" },
        }
        local t = build_task(typescript.tasks(ctx, "default"))
        assert.is_true(t.loomworks.applied_build_args)
        assert.is_nil(t.loomworks.applied_build_targets)
        local cmd = t.builder().cmd
        assert.is_true(has_seq(cmd, { "npm", "run", "build", "--", "--verbose" }),
            table.concat(cmd, " "))
        ctx.build_args = { "x&calc" }
        local t2 = build_task(typescript.tasks(ctx, "default"))
        assert.has_error(function() t2.builder() end)
    end)
end)

describe("run_build_steps fallback for a module that does not apply build args", function()
    local cli = require("loomworks.cli")
    local orig_plan, orig_spawn, orig_stderr, orig_exit, orig_write

    before_each(function()
        orig_plan, orig_spawn = overseer.plan_profile_build, cli._run_spec
        orig_stderr, orig_exit, orig_write = io.stderr, os.exit, io.write
    end)
    after_each(function()
        overseer.plan_profile_build, cli._run_spec = orig_plan, orig_spawn
        io.stderr, os.exit, io.write = orig_stderr, orig_exit, orig_write
    end)

    local function run(step, opts)
        overseer.plan_profile_build = function() return { step } end
        local spawned, err = {}, {}
        cli._run_spec = function(s) spawned[#spawned + 1] = s; return 0 end
        io.write = function() end
        io.stderr = { write = function(_, s) err[#err + 1] = s end }
        local code
        os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
        local ok, e = pcall(cli._run_build_steps, { key = "p" }, { root = "/r" }, opts)
        if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
        return spawned, code, table.concat(err)
    end

    it("appends to a plain command (previous behaviour)", function()
        local spawned = run({ kind = "build", name = "x", cmd = { "make" } },
            { extra_args = { "-k" } })
        assert.same({ "make", "-k" }, spawned[1].cmd)
    end)

    it("refuses to append to a batch-wrapped command", function()
        local spawned, code, err = run({ kind = "build", name = "x",
            cmd = { "cmd", "/C", "C:/b/loomworks_build_1.bat" } }, { extra_args = { "-k" } })
        assert.equals(1, code)
        assert.equals(0, #spawned)
        assert.matches("cannot forward", err)
    end)

    it("refuses to append to the env-named vcvars wrapper (cmake spec §14)", function()
        local spawned, code, err = run({ kind = "build", name = "x",
            cmd = { "cmd", "/d", "/v:on", "/c", "!LOOMWORKS_VCVARS_BAT!" },
            env = { LOOMWORKS_VCVARS_BAT = "C:/b/loomworks_build_1.bat" } },
            { extra_args = { "-k" } })
        assert.equals(1, code)
        assert.equals(0, #spawned)
        assert.matches("cannot forward", err)
    end)

    it("refuses --target for a module that does not support it", function()
        local spawned, code, err = run({ kind = "build", name = "App: build default",
            cmd = { "./build.sh" } }, { build_targets = { "X" } })
        assert.equals(1, code)
        assert.equals(0, #spawned)
        assert.matches("does not support %-%-target", err)
    end)
end)

describe("lw build completion", function()
    local cli = require("loomworks.cli")
    after_each(function() cli._reset_modes() end)

    local function complete(words)
        local buf = {}
        local rw = io.write
        io.write = function(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
        local ok, err = pcall(cli.cmd_complete, #words - 1, words)
        io.write = rw
        assert.is_true(ok, tostring(err))
        return table.concat(buf)
    end

    it("offers --target after the profile", function()
        local text = complete({ "lw", "build", "Debug:ninja-gcc-13", "" })
        assert.is_truthy(text:find("--target", 1, true), text)
    end)

    it("offers no target names for a profile that does not exist", function()
        assert.equals("", complete({ "lw", "build", "no-such-profile", "--target", "" }))
    end)
end)
