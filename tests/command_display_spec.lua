--- The configure / build command line is visible (headless §16.4, core §8.1
--- `display_cmd`): every configure and build step writes its argv + cwd to the
--- workspace log (CLI and editor task paths alike), `lw build -v/--verbose`
--- prints it under `==> [configure]`, and a wrapped command (cmake's vcvarsall
--- batch) is shown as the command the wrapper runs, not the wrapper.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local overseer = require("loomworks.overseer")
local term = require("loomworks.term")
local real_modules = require("loomworks.modules")

local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

--- cmake project App/Debug, profile `debug` on a gcc + Ninja tool whose cmake
--- is a real (empty) file under the temp root, so program hardening accepts it.
local function make_core()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    vim.fn.mkdir(root .. "/bin", "p")
    local cmake_path = root .. "/bin/cmake" .. (vim.fn.has("win32") == 1 and ".exe" or "")
    vim.fn.writefile({}, cmake_path)
    if vim.fn.has("win32") == 0 then vim.fn.setfperm(cmake_path, "rwxr-xr-x") end
    local tool = { key = "ninja-gcc-13",
        data = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = cmake_path } }
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = { cmake = { configurations = { Debug = {
                variant = "Debug", options = { FOO = "a b" },
            } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = tool.key, data = tool.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = modules_get },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = tool.key, tool_data = tool.data, tool_label = tool.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    cmake._cmake_version_cache = { [cmake_path] = { major = 3, minor = 28 } }
    return ws, ws._profiles[1], root
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, res = pcall(fn)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(res))
    return res
end

--- The workspace log — the real file `.nvim/loomworks.log` (Core's default
--- logger, rooted at the workspace).
local function log_text(ws)
    local f = io.open(ws.root .. "/.nvim/loomworks.log", "r")
    if not f then return "" end
    local s = f:read("*a"); f:close()
    return s
end

describe("term.format_argv", function()
    it("quotes only what needs it, readably", function()
        assert.equals('cmake -S "C:/my src" -B C:/b "-DX=a b" ""',
            term.format_argv({ "cmake", "-S", "C:/my src", "-B", "C:/b", "-DX=a b", "" }))
        assert.equals([["say \"hi\""]], term.format_argv({ 'say "hi"' }))
        assert.equals('"a&b" "x|y"', term.format_argv({ "a&b", "x|y" }))
    end)

    it("leaves control characters for the output layer to escape", function()
        local s = term.escape(term.format_argv({ "a\27[2Jb" }))
        assert.is_nil(s:find("\27", 1, true))
        assert.truthy(s:find("^[", 1, true))
    end)
end)

describe("configure / build command line", function()
    local orig_lookup = cpp.lookup_path
    local root
    before_each(function() cpp.lookup_path = function() return nil end end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        cmake._cmake_version_cache = {}
        package.loaded["overseer"] = nil
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    local function run_build(ws, profile, extra)
        local cli = require("loomworks.cli")
        local spawned, written = {}, {}
        local orig_spawn, orig_write = cli._run_spec, io.write
        cli._run_spec = function(step) spawned[#spawned + 1] = step; return 0 end
        io.write = function(...) for _, s in ipairs({ ... }) do written[#written + 1] = s end end
        local args = { "build", profile.key }
        for _, a in ipairs(extra or {}) do args[#args + 1] = a end
        local ok, err = pcall(function()
            with_ws(ws, function() return cli.cmd_build(ws, args) end)
        end)
        io.write = orig_write
        cli._run_spec = orig_spawn
        assert.is_true(ok, tostring(err))
        return spawned, table.concat(written)
    end

    it("lw build logs the configure and build argv + cwd, and prints nothing extra", function()
        local ws, profile, r = make_core()
        root = r
        local _, text = run_build(ws, profile)
        assert.is_nil(text:find("$ ", 1, true), text)
        local log = log_text(ws)
        assert.truthy(log:find("App: configure", 1, true), log)
        assert.truthy(log:find('-S ' .. root .. '/App', 1, true) or log:find("-S", 1, true), log)
        assert.truthy(log:find('"-DFOO=a b"', 1, true), log)
        assert.truthy(log:find("--build", 1, true), log)
        assert.truthy(log:find("(in " .. root .. "/App)", 1, true), log)
    end)

    it("lw build -v prints the configure argv and cwd under ==> [configure]", function()
        local ws, profile, r = make_core()
        root = r
        local _, text = run_build(ws, profile, { "-v" })
        local after = text:match("==> %[configure%][^\n]*\n(.*)")
        assert.is_not_nil(after, text)
        assert.truthy(after:find('    $ ' .. root .. '/bin/cmake', 1, true), text)
        assert.truthy(after:find('"-DFOO=a b"', 1, true), text)
        assert.truthy(after:find("    (in " .. root .. "/App)", 1, true), text)
        assert.truthy(text:find("==> [build]", 1, true), text)
        -- --verbose is the long form.
        local ws2, profile2, r2 = make_core()
        local _, text2 = run_build(ws2, profile2, { "--verbose" })
        vim.fn.delete(r2, "rf")
        assert.truthy(text2:find("    $ ", 1, true), text2)
    end)

    it("the editor task path logs the configure argv + cwd", function()
        local ws, profile, r = make_core()
        root = r
        local created = {}
        package.loaded["overseer"] = {
            new_task = function(spec)
                created[#created + 1] = spec
                return {
                    id = #created, subscribe = function() end, start = function() end,
                    is_complete = function() return false end,
                }
            end,
        }
        local unit = profile:projects()[1]._config_unit
        with_ws(ws, function() return overseer.run_configuration_action(unit, "configure") end)
        vim.wait(3000, function() return #created > 0 end)
        assert.equals(1, #created)
        assert.is_nil(created[1].display_cmd, "display_cmd is not handed to overseer")
        local log = log_text(ws)
        assert.truthy(log:find("App: configure", 1, true), log)
        assert.truthy(log:find('"-DFOO=a b"', 1, true), log)
        assert.truthy(log:find("(in " .. root .. "/App)", 1, true), log)
    end)

    if vim.fn.has("win32") == 1 then
        it("a vcvarsall-wrapped cmake command is shown as the inner cmake argv", function()
            local vroot = (vim.fn.tempname():gsub("\\", "/"))
            vim.fn.mkdir(vroot .. "/VS", "p")
            vim.fn.mkdir(vroot .. "/build", "p")
            local vcvarsall = vroot .. "/VS/vcvarsall.bat"
            vim.fn.writefile({ "@echo off" }, vcvarsall)
            local tasks = cmake.tasks({
                name = "App", path = "App", workspace_root = vroot,
                configurations = { Debug = { variant = "Debug", generator = "Ninja" } },
                tool_data = { generator = "Ninja", vcvarsall = vcvarsall, arch = "x64",
                    cmake_path = "C:/cm/cmake.exe" },
                cached_build_dir = vroot .. "/build",
            }, "Debug")
            local seen = {}
            for _, t in ipairs(tasks) do
                local spec = t.builder()
                seen[t.loomworks.action] = true
                assert.same({ "cmd", "/d", "/v:on", "/c", "!LOOMWORKS_VCVARS_BAT!" }, spec.cmd)
                assert.equals("C:/cm/cmake.exe", spec.display_cmd[1])
                local text = overseer.command_text(spec)
                assert.is_nil(text:find("VCVARS", 1, true), text)
                assert.truthy(text:find("C:/cm/cmake.exe", 1, true), text)
            end
            assert.is_true(seen.configure and seen.build)
            vim.fn.delete(vroot, "rf")
        end)
    end
end)
