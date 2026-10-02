-- A REAL cmake + ninja build routed through the workspace daemon (spec
-- §19.15, §19.19 step 3), with real `lw` processes: the daemon configures and
-- builds (artifact on disk, real tool output streamed back, `BUILD OK`), its
-- cache write-back is the in-process path's (the next build — routed or
-- in-process — does not reconfigure), and no process is left running.
--
-- Gated on a usable toolchain (cmake + ninja on PATH and a detected cmake
-- tool); anywhere else it is a pending() skip, never a failure.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local function have(exe) return vim.fn.executable(exe) == 1 end

--- A cmake tool key from `lw tools`: a self-contained ninja gcc/clang first
--- (no Visual Studio environment needed), then any ninja tool, else nil.
local function pick_tool(out)
    local keys = {}
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        local key = line:match("^%s+(ninja%-[%w%.%-]+)%s")
        if key then keys[#keys + 1] = key end
    end
    for _, k in ipairs(keys) do
        if (k:match("gcc") or k:match("clang")) and not k:match("clang%-cl") then return k end
    end
    return keys[1]
end

local function find_file(dir, name)
    local h = uv.fs_scandir(dir); if not h then return nil end
    while true do
        local entry, typ = uv.fs_scandir_next(h)
        if not entry then return nil end
        local full = dir .. "/" .. entry
        if typ == "directory" then
            local f = find_file(full, name); if f then return f end
        elseif entry == name then return full end
    end
end

describe("a real cmake build through the daemon", function()
    local root, env
    after_each(function()
        if root then H.track_root(root) end
        H.cleanup()
    end)

    local runnable = have("cmake") and have("ninja")
    local test = runnable and it or pending
    test("configures, builds and records like in-process; nothing reconfigures afterwards", function()
        root = H.tmp()
        vim.fn.mkdir(root .. "/app", "p")
        local f = io.open(root .. "/app/CMakeLists.txt", "w")
        f:write("cmake_minimum_required(VERSION 3.16)\nproject(app CXX)\nadd_executable(app main.cpp)\n")
        f:close()
        f = io.open(root .. "/app/main.cpp", "w")
        f:write('#include <cstdio>\nint main(){ std::printf("APP-RAN\\n"); return 0; }\n')
        f:close()
        env = H.env({ LOOMWORKS_RUNTIME = "in-process" })
        local function lw(args, mode)
            env.vars.LOOMWORKS_RUNTIME = mode or "in-process"
            return H.lw(args, { env = env, cwd = root, timeout = 600000 })
        end
        assert.equals(0, lw({ "init" }).code)
        local r = lw({ "--no-input", "project", "add", "./app", "cmake" })
        assert.equals(0, r.code, r.stderr)
        local tool = pick_tool(lw({ "tools" }).stdout)
        if not tool then
            pending("no ninja-based cmake tool detected")
            return
        end
        assert.equals(0, lw({ "--no-input", "configset", "create", "Debug", "app=variant:Debug" }).code)
        r = lw({ "--no-input", "profile", "create", "Debug", tool })
        assert.equals(0, r.code, r.stderr)
        local prof = "Debug:" .. tool

        r = lw({ "--no-input", "build", prof }, "daemon")
        assert.equals(0, r.code, r.stdout .. r.stderr)
        assert.truthy(r.stderr:find("lw: building through the workspace daemon (pid ", 1, true), r.stderr)
        assert.truthy(r.stdout:find("==> [configure]", 1, true), r.stdout)
        assert.truthy(r.stdout:find("BUILD OK: " .. prof, 1, true), r.stdout)
        -- Real build-tool output, streamed back.
        assert.truthy((r.stdout .. r.stderr):find("%[%d+/%d+%]") or r.stdout:find("Linking", 1, true), r.stdout)
        local exe = find_file(root .. "/.nvim/build", H.is_win and "app.exe" or "app")
        assert.truthy(exe, "no artifact")

        -- The daemon's cache write-back is the in-process one: neither a
        -- routed nor an in-process build reconfigures now.
        r = lw({ "--no-input", "build", prof }, "daemon")
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find("building through the workspace daemon", 1, true))
        assert.is_nil(r.stdout:find("[configure]", 1, true), r.stdout)
        r = lw({ "--no-input", "--no-daemon", "build", prof })
        assert.equals(0, r.code, r.stderr)
        assert.is_nil(r.stdout:find("[configure]", 1, true), r.stdout)
        assert.is_nil(r.stderr:find("building through the workspace daemon", 1, true))

        assert.equals(0, H.stop_daemon(root, env).code)
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
