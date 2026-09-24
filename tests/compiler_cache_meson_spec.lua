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
-- --wipe on launcher change (§5a / §11) — with the "none" sentinel + carve-out
-- ---------------------------------------------------------------------------
describe("meson compiler-cache reconfigure mechanism", function()
    it("uses --wipe when the launcher changed (none → ccache)", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "none", -- feature-configured, no cache
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--wipe"))
        assert.is_false(has_arg(cmd, "--reconfigure"))
    end)

    it("uses --reconfigure when the launcher is unchanged", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "/usr/bin/ccache",
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--reconfigure"))
        assert.is_false(has_arg(cmd, "--wipe"))
    end)

    it("wipes when a launcher was removed (recorded path, now off)", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            recorded_cache_launcher = "/usr/bin/ccache", -- had one
            -- compiler_cache nil → resolved "none" ≠ recorded path
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--wipe"))
    end)

    it("does NOT wipe a legacy build dir (nil recorded) when a cache appears", function()
        -- Legacy / never-recorded: unknown launcher state — a plain reconfigure,
        -- never a retroactive wipe (mirrors ConfigUnit:launcher_changed).
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = nil,
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_false(has_arg(cmd, "--wipe"))
        assert.is_true(has_arg(cmd, "--reconfigure"))
    end)

    it("off stays off: recorded \"none\", still no cache → plain reconfigure", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            recorded_cache_launcher = "none",
            -- compiler_cache nil → resolved "none" == recorded "none"
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_false(has_arg(cmd, "--wipe"))
        assert.is_true(has_arg(cmd, "--reconfigure"))
    end)

    it("first-time setup uses neither --wipe nor --reconfigure", function()
        local c = ctx({
            cached_build_dir = vim.fn.tempname(), -- does not exist
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "none",
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_false(has_arg(cmd, "--wipe"))
        assert.is_false(has_arg(cmd, "--reconfigure"))
    end)

    it("--wipe preserves the -D options (buildtype survives)", function()
        local dir = setup_build_dir()
        local c = ctx({
            cached_build_dir = dir,
            compiler_cache = { tool = "ccache", path = "/usr/bin/ccache" },
            recorded_cache_launcher = "none",
        })
        local cmd = meson.tasks(c, "Debug")[1].builder().cmd
        assert.is_true(has_arg(cmd, "--buildtype=debug"))
    end)
end)

-- ---------------------------------------------------------------------------
-- Faithful reconfigure for a REMOVED option (meson §5a, core §5.1): meson keeps
-- a no-longer-passed -D on --reconfigure and --wipe replays the stored command
-- line, so core must clear meson-private/cmd_line.txt before a --wipe setup.
-- ---------------------------------------------------------------------------
describe("meson faithful reconfigure (removed option)", function()
    local function configure_task(c)
        for _, t in ipairs(meson.tasks(c, "Debug")) do
            if t.loomworks.action == "configure" then return t end
        end
    end

    it("records the -D options it passed", function()
        local t = configure_task(ctx({
            type_config = { options = { werror = "true" } },
            recorded_cache_launcher = "none",
        }))
        assert.same({ werror = "true" }, t.loomworks.module_info.passed_options)
    end)

    it("a removed option resets the stored command line and wipes", function()
        local dir = setup_build_dir()
        local t = configure_task(ctx({
            cached_build_dir = dir,
            recorded_cache_launcher = "none",
            recorded_module_info = { cache_launcher = "none", passed_options = { werror = "true" } },
        }))
        assert.same({ "meson-private/cmd_line.txt" }, t.loomworks.pre_configure_reset)
        local cmd = t.builder().cmd
        assert.is_true(has_arg(cmd, "--wipe"))
        assert.is_false(has_arg(cmd, "--reconfigure"))
    end)

    it("an added or changed option is a plain --reconfigure (no reset)", function()
        local dir = setup_build_dir()
        local t = configure_task(ctx({
            cached_build_dir = dir,
            type_config = { options = { werror = "false", b_lto = "true" } },
            recorded_cache_launcher = "none",
            recorded_module_info = { cache_launcher = "none", passed_options = { werror = "true" } },
        }))
        assert.is_nil(t.loomworks.pre_configure_reset)
        assert.is_true(has_arg(t.builder().cmd, "--reconfigure"))
    end)

    it("a legacy unit falls back to core's option snapshot", function()
        local dir = setup_build_dir()
        local t = configure_task(ctx({
            cached_build_dir = dir,
            recorded_cache_launcher = "none",
            recorded_module_info = { cache_launcher = "none" },
            recorded_options = { werror = "true" },
        }))
        assert.same({ "meson-private/cmd_line.txt" }, t.loomworks.pre_configure_reset)
        assert.is_true(has_arg(t.builder().cmd, "--wipe"))
    end)
end)
