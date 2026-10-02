--- VS 2022's vcvarsall.bat (VsDevCmd.bat and its ext scripts) runs
--- `vswhere.exe` by bare name. It lives in
--- "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer", which is usually
--- not on PATH, so every vcvarsall run printed "'vswhere.exe' is not
--- recognized ...". Every environment loomworks runs vcvarsall in — the cmake
--- Ninja+MSVC wrapper and the msvc.vcvars_env probe (meson) — gets the
--- Installer folder appended to PATH when it exists, at most once.

local msvc = require("loomworks.msvc")
local cmake = require("loomworks.modules.cmake")

local WIN = vim.fn.has("win32") == 1

local function norm(p) return (p:gsub("/", "\\"):gsub("\\+$", ""):lower()) end

--- Entries of a ;-separated PATH equal (case/slash-insensitively) to `dir`.
local function count_entries(path, dir)
    local n = 0
    for e in (path or ""):gmatch("[^;]+") do
        if norm(e) == norm(dir) then n = n + 1 end
    end
    return n
end

--- The env value for `name`, case-insensitively, and how many keys match.
local function env_get(env, name)
    local v, n = nil, 0
    for k, val in pairs(env or {}) do
        if k:upper() == name:upper() then v = val; n = n + 1 end
    end
    return v, n
end

describe("msvc VS Installer dir on the vcvarsall PATH", function()
    local root, saved_getenv
    local fake = {}

    before_each(function()
        root = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(root, "p")
        saved_getenv = msvc._getenv
        fake = { PATH = [[C:\Windows\system32;C:\Windows]] }
        msvc._getenv = function(k)
            for fk, v in pairs(fake) do
                if fk:upper() == k:upper() then return v end
            end
            return nil
        end
    end)
    after_each(function()
        msvc._getenv = saved_getenv
        vim.fn.delete(root, "rf")
    end)

    local function make_installer(base)
        local dir = base .. "/Microsoft Visual Studio/Installer"
        vim.fn.mkdir(dir, "p")
        return (dir:gsub("/", "\\"))
    end

    it("installer_dir resolves ProgramFiles(x86), falls back to ProgramFiles, never a missing dir", function()
        fake["ProgramFiles(x86)"] = root .. "/pf86"
        fake["ProgramFiles"] = root .. "/pf"
        assert.is_nil(msvc.installer_dir())
        local pf = make_installer(root .. "/pf")
        assert.equals(norm(pf), norm(msvc.installer_dir()))
        local pf86 = make_installer(root .. "/pf86")
        assert.equals(norm(pf86), norm(msvc.installer_dir()))
        fake["ProgramFiles(x86)"] = nil; fake["ProgramFiles"] = nil
        assert.is_nil(msvc.installer_dir())
    end)

    it("with_installer_path appends the dir once to the inherited PATH", function()
        fake["ProgramFiles(x86)"] = root .. "/pf86"
        local dir = make_installer(root .. "/pf86")
        local env = msvc.with_installer_path({ FOO = "1" })
        local path, n = env_get(env, "PATH")
        assert.equals(1, n)
        assert.equals("1", env.FOO)
        assert.is_truthy(path:find([[C:\Windows\system32]], 1, true), path)
        assert.equals(1, count_entries(path, dir))
        assert.equals(norm(dir), norm(path:match("([^;]+)$")), "appended, not prepended: " .. path)
        -- Idempotent: running it over its own result adds nothing.
        local again = msvc.with_installer_path(env)
        assert.equals(path, (env_get(again, "PATH")))
    end)

    it("does not duplicate a dir already on PATH (case/slash-insensitive)", function()
        fake["ProgramFiles(x86)"] = root .. "/pf86"
        local dir = make_installer(root .. "/pf86")
        fake.PATH = [[C:\Windows;]] .. dir:upper():gsub("\\", "/") .. "/"
        local env = msvc.with_installer_path({})
        local path = env_get(env, "PATH") or fake.PATH
        assert.equals(1, count_entries(path, dir))
        -- A step env that already carries Path (any case) is extended in place.
        local env2 = msvc.with_installer_path({ Path = [[C:\x]] })
        local p2, n2 = env_get(env2, "PATH")
        assert.equals(1, n2)
        assert.equals([[C:\x;]] .. dir, p2)
    end)

    it("leaves the env alone when the Installer dir does not exist", function()
        fake["ProgramFiles(x86)"] = root .. "/nope"
        local env = msvc.with_installer_path({ FOO = "1" })
        assert.same({ FOO = "1" }, env)
    end)

    if WIN then
        it("the cmake vcvarsall wrapper env carries the Installer dir", function()
            fake["ProgramFiles(x86)"] = root .. "/pf86"
            local dir = make_installer(root .. "/pf86")
            vim.fn.mkdir(root .. "/VS", "p")
            local vcvarsall = root .. "/VS/vcvarsall.bat"
            vim.fn.writefile({ "@echo off" }, vcvarsall)
            local bd = root .. "/build"
            vim.fn.mkdir(bd, "p")
            local _, env = cmake._wrap_cmd({ "cmake", "--build", "." },
                { vcvarsall = vcvarsall, arch = "x64" }, "Ninja", bd, "build", { X = "y" })
            local path, n = env_get(env, "PATH")
            assert.equals(1, n)
            assert.equals(1, count_entries(path, dir))
            assert.equals("y", env.X)
            assert.is_string(env.LOOMWORKS_VCVARS_BAT)

            -- No Installer dir: no PATH override at all.
            fake["ProgramFiles(x86)"] = root .. "/nope"
            local _, env2 = cmake._wrap_cmd({ "cmake", "--build", "." },
                { vcvarsall = vcvarsall, arch = "x64" }, "Ninja", bd, "build", { X = "y" })
            local _, n2 = env_get(env2, "PATH")
            assert.equals(0, n2)
        end)

        it("the vcvars_env probe runs with the Installer dir on PATH", function()
            fake["ProgramFiles(x86)"] = root .. "/pf86"
            local dir = make_installer(root .. "/pf86")
            vim.fn.mkdir(root .. "/VS", "p")
            local vcvarsall = root .. "/VS/vcvarsall.bat"
            vim.fn.writefile({ "@echo off" }, vcvarsall)
            local saved = vim.system
            local seen
            vim.system = function(_, opts)
                seen = opts
                return { wait = function() return { code = 0, stdout = "INCLUDE=i\r\nLIB=l\r\n" } end }
            end
            msvc._env = {}
            local env = msvc.vcvars_env(vcvarsall, "x64")
            vim.system = saved
            msvc._env = {}
            assert.is_table(env)
            local path = env_get(seen and seen.env, "PATH")
            assert.is_string(path)
            assert.equals(1, count_entries(path, dir))
        end)
    end
end)

if WIN then
describe("real vcvarsall (Windows, VS installed)", function()
    it("runs without the 'vswhere.exe is not recognized' noise", function()
        local installs = msvc.detect() or {}
        local inst = installs[1]
        if not inst then pending("no Visual Studio install") return end
        local bd = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(bd, "p")
        local comspec = vim.fn.exepath("cmd.exe")
        local argv, env = cmake._wrap_cmd({ comspec, "/d", "/c", "echo", "LW_OK" },
            { vcvarsall = inst.vcvarsall, arch = "x64" }, "Ninja", bd, "probe", {})
        local hardened = assert(require("loomworks.exe").harden_spec({ cmd = argv, env = env }))
        local res = vim.system(hardened.cmd, { env = hardened.env, text = true }):wait(120000)
        vim.fn.delete(bd, "rf")
        local all = (res.stdout or "") .. (res.stderr or "")
        assert.equals(0, res.code, all)
        assert.is_truthy(all:find("LW_OK", 1, true), all)
        assert.is_nil(all:lower():find("vswhere.exe' is not recognized", 1, true), all)
    end)
end)
end
