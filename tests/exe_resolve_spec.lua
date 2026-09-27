--- Bare program names are resolved to absolute paths from absolute PATH entries
--- only — never from the current directory or an empty/relative PATH entry —
--- before anything is spawned (loomworks.exe).
---
--- The fixture is benign: a copy of a harmless system tool (whoami on Windows,
--- `true` elsewhere) renamed to `lwprobe`, placed in a scratch directory that is
--- also the current directory. Every assertion is "was it found / did it run?".

local exe = require("loomworks.exe")
local uv = vim.uv or vim.loop

local IS_WIN = vim.fn.has("win32") == 1
local PROBE = IS_WIN and "lwprobe.exe" or "lwprobe"

local function copy_probe(dir)
    local src = IS_WIN and ((os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\whoami.exe")
        or (vim.fn.exepath("true") ~= "" and vim.fn.exepath("true") or "/bin/true")
    assert(uv.fs_copyfile(src, dir .. "/" .. PROBE))
    if not IS_WIN then uv.fs_chmod(dir .. "/" .. PROBE, 493) end
end

local function norm(p) return (p:gsub("\\", "/"):lower()) end

describe("loomworks.exe", function()
    local saved_cwd, tmp

    before_each(function()
        saved_cwd = uv.cwd()
        tmp = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(tmp, "p")
        copy_probe(tmp)
    end)

    after_each(function()
        uv.chdir(saved_cwd)
        vim.fn.delete(tmp, "rf")
    end)

    it("does not resolve a program that exists only in the current directory", function()
        uv.chdir(tmp)
        local p, err = exe.resolve("lwprobe")
        uv.chdir(saved_cwd)
        assert.is_nil(p)
        assert.matches("not found on PATH", err, 1, true)
    end)

    it("ignores empty and relative PATH entries", function()
        local sep = IS_WIN and ";" or ":"
        uv.chdir(tmp)
        local p1 = exe.resolve("lwprobe", { PATH = "." .. sep .. sep .. "sub" })
        local p2 = exe.resolve("lwprobe", { PATH = sep })
        uv.chdir(saved_cwd)
        assert.is_nil(p1)
        assert.is_nil(p2)
    end)

    it("resolves from an absolute PATH entry to an absolute path", function()
        local p = exe.resolve("lwprobe", { PATH = tmp })
        assert.is_string(p)
        assert.is_true(exe.is_absolute(p))
        assert.equals(norm(tmp .. "/" .. PROBE), norm(p))
    end)

    it("refuses a relative path with a separator", function()
        uv.chdir(tmp)
        local p, err = exe.resolve("./lwprobe")
        uv.chdir(saved_cwd)
        assert.is_nil(p)
        assert.matches("relative program path", err, 1, true)
    end)

    it("accepts an existing absolute path", function()
        local abs = tmp .. "/lwprobe"
        assert.is_string(exe.resolve(abs))
    end)

    if IS_WIN then
        it("resolves cmd to %SystemRoot%\\System32\\cmd.exe, never via PATH/cwd", function()
            vim.fn.writefile({ "@echo off" }, tmp .. "/cmd.bat")
            uv.chdir(tmp)
            local p = exe.resolve("cmd", { PATH = tmp })
            uv.chdir(saved_cwd)
            assert.equals(norm((os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\cmd.exe"), norm(p))
            assert.is_nil(p:find("/", 1, true), "cmd.exe path must use backslashes")
        end)

        it("harden_spec sets NoDefaultCurrentDirectoryInExePath in the task env", function()
            local spec = exe.harden_spec({ cmd = { "lwprobe", "/?" }, env = { PATH = tmp } })
            assert.equals("1", spec.env.NoDefaultCurrentDirectoryInExePath)
            assert.equals(norm(tmp .. "/" .. PROBE), norm(spec.cmd[1]))
            assert.equals("/?", spec.cmd[2])
        end)
    end

    it("editor_exepath drops a current-directory hit from vim.fn.exepath", function()
        local orig = vim.fn.exepath
        vim.fn.exepath = function() return tmp .. "/" .. PROBE end   -- as Neovim < 0.12 on Windows
        uv.chdir(tmp)
        local got = exe.editor_exepath("lwprobe")
        uv.chdir(saved_cwd)
        vim.fn.exepath = function() return "C:/py/Scripts/meson.exe" end
        local kept = exe.editor_exepath("meson")
        vim.fn.exepath = function() return "" end
        local none = exe.editor_exepath("meson")
        vim.fn.exepath = orig
        assert.equals("", got)
        assert.equals("C:/py/Scripts/meson.exe", kept)
        assert.equals("", none)
    end)

    it("harden_spec resolves an explicit relative path against the task cwd only", function()
        local spec = exe.harden_spec({ cmd = { "./lwprobe" }, cwd = tmp })
        assert.equals(norm(tmp .. "/" .. PROBE), norm(spec.cmd[1]))
        assert.is_nil(exe.harden_spec({ cmd = { "./lwprobe" } }))
    end)

    it("harden_spec refuses an unresolvable program", function()
        uv.chdir(tmp)
        local spec, err = exe.harden_spec({ cmd = { "lwprobe" } })
        uv.chdir(saved_cwd)
        assert.is_nil(spec)
        assert.matches("not found on PATH", err, 1, true)
    end)

    it("exe.system never spawns a cwd-only program (code 127)", function()
        uv.chdir(tmp)
        local res = exe.system({ "lwprobe" }, { text = true }):wait()
        uv.chdir(saved_cwd)
        assert.equals(127, res.code)
        assert.matches("not found on PATH", res.stderr, 1, true)
    end)

    it("cli run_spec does not run a cwd-only program", function()
        _G.LOOMWORKS_CLI_NO_AUTORUN = true
        local cli = require("loomworks.cli")
        local rw, rs = io.write, io.stderr
        local err_buf = {}
        io.write = function() end
        io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
        local ok, code = pcall(cli._run_spec, { cmd = { "lwprobe" }, cwd = tmp }, tmp)
        io.write, io.stderr = rw, rs
        assert.is_true(ok, tostring(code))
        assert.are_not.equal(0, code)
        assert.matches("not found on PATH", table.concat(err_buf), 1, true)
    end)
end)
