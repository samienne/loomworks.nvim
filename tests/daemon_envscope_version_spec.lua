-- The workspace daemon's environment signature (spec §19.15: per-session
-- terminal variables do not make two terminals different environments), the
-- Windows safety variable kept in a client's scope, and the development
-- version identity of a `luvi <dir>` daemon (spec §19.9: a source edit is a
-- version mismatch).

local envscope = require("loomworks.daemon.envscope")
local version = require("loomworks.daemon.version")
local uv = vim.uv or vim.loop

local WIN = package.config:sub(1, 1) == "\\"

describe("envscope.signature", function()
    it("ignores per-terminal and per-session variables, not PATH", function()
        local function env(tag, path)
            return { PATH = path or "/usr/bin", HOME = "/home/u", WT_SESSION = "w" .. tag,
                WT_PROFILE_ID = "p" .. tag, TERM_SESSION_ID = "t" .. tag, ITERM_SESSION_ID = "i" .. tag,
                TMUX = "/tmp/" .. tag, TMUX_PANE = "%" .. tag, STY = "s" .. tag, WINDOW = tag,
                SSH_CLIENT = "c" .. tag, SSH_CONNECTION = "n" .. tag, SSH_TTY = "y" .. tag,
                SSH_AUTH_SOCK = "/tmp/agent." .. tag, WINDOWID = tag, GPG_TTY = "g" .. tag,
                VSCODE_GIT_IPC_HANDLE = "v" .. tag, VSCODE_IPC_HOOK_CLI = "h" .. tag,
                VSCODE_INJECTION = tag, TERM_PROGRAM_VERSION = "1." .. tag,
                KONSOLE_DBUS_SESSION = "k" .. tag, KONSOLE_DBUS_WINDOW = "kw" .. tag,
                ALACRITTY_WINDOW_ID = tag, KITTY_WINDOW_ID = tag, KITTY_PID = tag, WEZTERM_PANE = tag,
                XDG_SESSION_ID = tag, ZELLIJ_PANE_ID = tag, NVIM = "/tmp/nvim." .. tag,
                ["_"] = "/usr/bin/lw" .. tag, PWD = "/w/" .. tag, OLDPWD = "/o/" .. tag, SHLVL = tag }
        end
        assert.equals(envscope.signature(env("1")), envscope.signature(env("2")))
        assert.are_not.equal(envscope.signature(env("1")), envscope.signature(env("1", "/opt/bin:/usr/bin")))
        -- A variable a build may read is never ignored.
        local e = env("1"); e.CC = "clang"
        assert.are_not.equal(envscope.signature(env("1")), envscope.signature(e))
        local v = env("1"); v.VSCODE_X = nil; v.VSCODEX = "1"
        assert.are_not.equal(envscope.signature(env("1")), envscope.signature(v))
    end)

    it("matches names case-insensitively on Windows", function()
        if not WIN then return pending("Windows only") end
        local a = { Path = "C:\\x", wt_session = "1", Vscode_Git_Ipc_Handle = "a" }
        local b = { Path = "C:\\x", WT_SESSION = "2", VSCODE_GIT_IPC_HANDLE = "b" }
        assert.equals(envscope.signature(a), envscope.signature(b))
    end)
end)

describe("envscope.with on Windows", function()
    it("keeps NoDefaultCurrentDirectoryInExePath set in a client's scope that lacks it", function()
        if not WIN then return pending("Windows only") end
        local env = envscope.capture()
        for k in pairs(env) do
            if k:upper() == "NODEFAULTCURRENTDIRECTORYINEXEPATH" then env[k] = nil end
        end
        local got = envscope.with(env, function() return uv.os_getenv("NoDefaultCurrentDirectoryInExePath") end)
        assert.equals("1", got)
    end)
end)

describe("version.identity of a development source", function()
    local saved_luvi, saved_root
    before_each(function()
        saved_luvi = package.loaded.luvi
        saved_root = version.lua_root
    end)
    after_each(function()
        package.loaded.luvi = saved_luvi
        version.lua_root = saved_root
        version._set_identity(nil)
    end)

    local function write(path, text)
        local f = assert(io.open(path, "wb")); f:write(text); f:close()
    end

    it("a `luvi <dir>` bundle fingerprints its source tree: an edit changes the identity", function()
        local dir = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(dir .. "/loomworks/daemon", "p")
        write(dir .. "/loomworks/cli.lua", "return 1")
        write(dir .. "/loomworks/daemon/x.lua", "return 2")
        package.loaded.luvi = { bundle = { base = dir } }
        -- Modules come from the bundle: no on-disk root of their own.
        version.lua_root = function() return nil end
        version._set_identity(nil)
        local a = version.identity()
        assert.is_true(version.is_dev(a))
        version._set_identity(nil)
        assert.equals(a, version.identity())
        write(dir .. "/loomworks/daemon/x.lua", "return 22")
        version._set_identity(nil)
        local b = version.identity()
        assert.is_true(version.is_dev(b))
        assert.are_not.equal(a, b)
    end)

    it("a fused executable (bundle base is a file) keeps the executable fingerprint", function()
        local file = (vim.fn.tempname():gsub("\\", "/"))
        write(file, "exe")
        package.loaded.luvi = { bundle = { base = file } }
        version.lua_root = function() return nil end
        version._set_identity(nil)
        local a = version.identity()
        write(file, "exe changed")
        version._set_identity(nil)
        assert.equals(a, version.identity())
    end)

    it("a fused executable has one identity whatever path spelling reaches it (lw.exe / lw.EXE / a link)", function()
        local dir = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(dir, "p")
        local exe = dir .. "/lw.exe"
        write(exe, "exe")
        package.loaded.luvi = { bundle = { base = exe } }
        version.lua_root = function() return nil end
        local uv = vim.uv or vim.loop
        local spellings = { exe, (exe:gsub("/", "\\")) }
        if vim.fn.has("win32") == 1 then spellings[#spellings + 1] = dir .. "/lw.EXE" end
        local link = dir .. "/link-lw.exe"
        if uv.fs_symlink(exe, link) then spellings[#spellings + 1] = link end
        local saved_exepath = uv.exepath
        local ids = {}
        local ok, err = pcall(function()
            for _, p in ipairs(spellings) do
                uv.exepath = function() return p end
                version._set_identity(nil)
                ids[#ids + 1] = version.identity()
            end
        end)
        uv.exepath = saved_exepath
        assert(ok, err)
        for i = 2, #ids do assert.equals(ids[1], ids[i]) end
    end)
end)
