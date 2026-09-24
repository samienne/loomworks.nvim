--- Tests for the meson module's compiler-cache launcher application (§5a, §11).
---
--- Exercises `meson.tasks()` with a core-resolved `compiler_cache` on the
--- project context: the **native-file** compiler+launcher pinning (space-safe
--- — meson shlex-splits CC/CXX env, so a spaced path must ride a native-file
--- list), the `--wipe`-on-launcher-change reconfigure (with the "none" sentinel
--- + legacy carve-out), and `module_info.cache_launcher` recording.

local meson = require("loomworks.modules.meson")

local function has_arg(cmd, arg)
    for _, a in ipairs(cmd) do if a == arg then return true end end
    return false
end

local function has_arg_starting(cmd, prefix)
    for _, a in ipairs(cmd) do if a:sub(1, #prefix) == prefix then return a end end
    return nil
end

local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local c = fh:read("*a"); fh:close()
    return c
end

--- A build dir that meson considers "already set up" (has meson-info/).
local function setup_build_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/meson-info", "p")
    return dir
end

local function ctx(overrides)
    local c = {
        name = "App",
        path = "app",
        workspace_root = "/root",
        tool_data = {
            meson = { "/usr/bin/meson" },
            compiler_c_path = "/usr/bin/gcc",
            compiler_path = "/usr/bin/g++",
        },
        configurations = { Debug = { buildtype = "debug" } },
        env = {},
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

-- ---------------------------------------------------------------------------
-- Native-file body (space-safe compiler+launcher pinning) — Bug 1
-- ---------------------------------------------------------------------------
describe("meson native-file compiler pinning", function()
    it("keeps launcher + a SPACED compiler path as separate list tokens", function()
        local body = meson._meson_native_file_body(
            "C:/Program Files/LLVM/bin/clang.exe",
            "C:/Program Files/LLVM/bin/clang++.exe",
            "C:/tools/ccache.exe")
        assert.is_truthy(body:find("[binaries]", 1, true))
        -- The spaced path is ONE quoted element, the launcher another — meson
        -- does not shell-split a list, so `C:/Program Files/...` stays intact.
        assert.is_truthy(body:find(
            "c = ['C:/tools/ccache.exe', 'C:/Program Files/LLVM/bin/clang.exe']", 1, true))
        assert.is_truthy(body:find(
            "cpp = ['C:/tools/ccache.exe', 'C:/Program Files/LLVM/bin/clang++.exe']", 1, true))
    end)

    it("pins the bare compiler as a single token when no launcher", function()
        local body = meson._meson_native_file_body(
            "C:/Program Files/mingw/bin/gcc.exe",
            "C:/Program Files/mingw/bin/g++.exe", nil)
        assert.is_truthy(body:find("c = ['C:/Program Files/mingw/bin/gcc.exe']", 1, true))
        assert.is_truthy(body:find("cpp = ['C:/Program Files/mingw/bin/g++.exe']", 1, true))
    end)

    it("normalizes backslashes to forward slashes", function()
        local body = meson._meson_native_file_body("C:\\LLVM\\clang.exe", nil, nil)
        assert.is_truthy(body:find("c = ['C:/LLVM/clang.exe']", 1, true))
    end)

    it("returns nil when no compiler command is known", function()
        assert.is_nil(meson._meson_native_file_body(nil, nil, "ccache"))
        assert.is_nil(meson._meson_native_file_body("", "", nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- Integration: env CC/CXX dropped, --native-file passed, file written — Bug 1
-- ---------------------------------------------------------------------------
describe("meson compiler pinning through tasks()", function()
    it("drops CC/CXX from the setup env and passes --native-file", function()
        local dir = vim.fn.tempname()
        local c = ctx({
            cached_build_dir = dir,
            tool_data = { meson = { "/usr/bin/meson" },
                compiler_c_path = "C:/Program Files/LLVM/bin/clang.exe",
                compiler_path = "C:/Program Files/LLVM/bin/clang++.exe" },
            compiler_cache = { tool = "ccache", path = "C:/tools/ccache.exe" },
        })
        local spec = meson.tasks(c, "Debug")[1].builder()
        -- meson would shlex-split a spaced CC/CXX env — so they MUST be absent.
        assert.is_nil(spec.env.CC)
        assert.is_nil(spec.env.CXX)
        local nf = dir .. ".lw-native.ini"
        assert.equals("--native-file=" .. nf, has_arg_starting(spec.cmd, "--native-file="))
        -- The file is written with the intact spaced path as a list element.
        local body = read_file(nf)
        assert.is_truthy(body)
        assert.is_truthy(body:find(
            "cpp = ['C:/tools/ccache.exe', 'C:/Program Files/LLVM/bin/clang++.exe']", 1, true))
    end)

    it("writes no native file when the tool pins no compiler", function()
        local c = {
            name = "App", path = "app", workspace_root = "/root",
            tool_data = { meson = { "/usr/bin/meson" } },
            configurations = { Debug = { buildtype = "debug" } }, env = {},
        }
        local spec = meson.tasks(c, "Debug")[1].builder()
        assert.is_nil(has_arg_starting(spec.cmd, "--native-file="))
    end)

    it("records the launcher in module_info, or \"none\" when off", function()
        local c = ctx({ compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" } })
        assert.equals("/usr/bin/ccache",
            meson.tasks(c, "Debug")[1].loomworks.module_info.cache_launcher)
        -- Explicit "none" (not nil) so is_stale distinguishes feature-no-cache
        -- from a legacy/never-recorded unit.
        assert.equals("none",
            meson.tasks(ctx({}), "Debug")[1].loomworks.module_info.cache_launcher)
    end)
end)

-- ---------------------------------------------------------------------------
-- Full reconfigure for EVERY changed configure input (meson §5a, core §5.1):
-- meson fixes the compiler command, env-derived args and machine files at the
-- first setup, keeps a no-longer-passed -D on --reconfigure, and --wipe replays
-- the stored command line — so any change clears meson-private/cmd_line.txt
-- (core reset) and runs `setup --wipe`. No in-place set; an unchanged re-setup
-- runs --reconfigure.
-- ---------------------------------------------------------------------------
describe("meson full reconfigure on any changed configure input", function()
    local function configure_task(c)
        for _, t in ipairs(meson.tasks(c, "Debug")) do
            if t.loomworks.action == "configure" then return t end
        end
    end

    --- The record a plain (no options, no cache) Debug setup leaves behind.
    local function rec(extra)
        local r = { cache_launcher = "none", passed_options = {}, buildtype = "debug",
            record_version = require("loomworks.modules.meson").configure_record_version }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end

    local function is_full(t)
        local cmd = t.builder().cmd
        return vim.deep_equal({ "meson-private/cmd_line.txt" }, t.loomworks.pre_configure_reset)
            and has_arg(cmd, "--wipe") and not has_arg(cmd, "--reconfigure")
    end

    local function is_in_place(t)
        local cmd = t.builder().cmd
        return t.loomworks.pre_configure_reset == nil
            and has_arg(cmd, "--reconfigure") and not has_arg(cmd, "--wipe")
    end

    it("records the -D options, build type and cross file it passed", function()
        local t = configure_task(ctx({
            type_config = { options = { werror = "true" } },
            configurations = { Debug = { buildtype = "debug", machine_file = "/x/cross.ini" } },
        }))
        local mi = t.loomworks.module_info
        assert.same({ werror = "true" }, mi.passed_options)
        assert.equals("debug", mi.buildtype)
        assert.equals("/x/cross.ini", mi.cross_file)
    end)

    it("an unchanged setup is a plain --reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            recorded_cache_launcher = "none",
            recorded_module_info = rec(),
        }))
        assert.is_true(is_in_place(t))
    end)

    it("an unchanged launcher stays in place", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "/usr/bin/ccache",
            recorded_module_info = rec({ cache_launcher = "/usr/bin/ccache" }),
        }))
        assert.is_true(is_in_place(t))
    end)

    it("a launcher that appeared (none → ccache) is a full reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "none",
            recorded_module_info = rec(),
        }))
        assert.is_true(is_full(t))
    end)

    it("a launcher that disappeared is a full reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            recorded_cache_launcher = "/usr/bin/ccache",
            recorded_module_info = rec({ cache_launcher = "/usr/bin/ccache" }),
        }))
        assert.is_true(is_full(t))
    end)

    it("a removed option is a full reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            recorded_cache_launcher = "none",
            recorded_module_info = rec({ passed_options = { werror = "true" } }),
        }))
        assert.is_true(is_full(t))
    end)

    it("an added or changed option is a full reconfigure (no in-place set)", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            type_config = { options = { werror = "false", b_lto = "true" } },
            recorded_cache_launcher = "none",
            recorded_module_info = rec({ passed_options = { werror = "true" } }),
        }))
        assert.is_true(is_full(t))
    end)

    it("a changed build type is a full reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            recorded_cache_launcher = "none",
            recorded_module_info = rec({ buildtype = "release" }),
        }))
        assert.is_true(is_full(t))
    end)

    it("a changed cross file is a full reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            configurations = { Debug = { buildtype = "debug", machine_file = "/x/new.ini" } },
            recorded_cache_launcher = "none",
            recorded_module_info = rec({ cross_file = "/x/old.ini" }),
        }))
        assert.is_true(is_full(t))
    end)

    it("a changed configuration environment is a full reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            configuration_env = { CFLAGS = "-O1" },
            recorded_cache_launcher = "none",
            recorded_module_info = rec({ configure_env = { CFLAGS = "-O2" } }),
        }))
        assert.is_true(is_full(t))
    end)

    it("an unchanged configuration environment stays in place", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            configuration_env = { CFLAGS = "-O2" },
            recorded_cache_launcher = "none",
            recorded_module_info = rec({ configure_env = { CFLAGS = "-O2" } }),
        }))
        assert.is_true(is_in_place(t))
    end)

    it("a configured unit with no passed_options record takes the full path", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_options = { werror = "true" },
        }))
        assert.is_true(is_full(t))
    end)

    it("first-time setup uses neither --wipe nor --reconfigure", function()
        local t = configure_task(ctx({
            cached_build_dir = vim.fn.tempname(), -- does not exist
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
        }))
        local cmd = t.builder().cmd
        assert.is_false(has_arg(cmd, "--wipe"))
        assert.is_false(has_arg(cmd, "--reconfigure"))
        assert.is_nil(t.loomworks.pre_configure_reset)
    end)

    it("the --wipe setup re-passes every loomworks input (buildtype, -D)", function()
        local t = configure_task(ctx({
            cached_build_dir = setup_build_dir(),
            type_config = { options = { werror = "true" } },
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "none",
            recorded_module_info = rec(),
        }))
        local cmd = t.builder().cmd
        assert.is_true(has_arg(cmd, "--wipe"))
        assert.is_true(has_arg(cmd, "--buildtype=debug"))
        assert.is_true(has_arg(cmd, "-Dwerror=true"))
    end)
end)
