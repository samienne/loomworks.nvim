-- A routed `lw build` from cmd.exe / PowerShell / a VS developer prompt, and
-- the one line of every build the daemon does not run (spec §19.15), plus the
-- handle's rename over a file a client is reading (spec §19.6).
--
-- cmd.exe gives every process it starts hidden `=`-prefixed entries in the
-- environment block (`=C:=C:\src`, `=ExitCode=00000000`), and so does every
-- process started from one (a `.cmd` shim, a PowerShell or VS prompt opened
-- from a cmd-hosted console). The client sends its whole environment with a
-- build request; the daemon used to reject such a name as malformed and
-- decline the request, and the client fell back in-process without a word.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local handle = require("loomworks.daemon.handle")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

client.TIMEOUT_MS = 30000

local WIN = package.config:sub(1, 1) == "\\"

--- What cmd.exe adds to a child's environment.
local CMD_ENTRIES = { ["=C:"] = [[C:\Users\me\src]], ["=D:"] = [[D:\work]], ["=ExitCode"] = "00000000" }

describe("envscope: the Windows `=`-prefixed environment entries", function()
    it("travel in a request on Windows (validate), and are never part of the signature", function()
        local env = { PATH = "/bin", PROMPT = "$P$G" }
        for k, v in pairs(CMD_ENTRIES) do env[k] = v end
        local ok, err = envscope.validate(env)
        if WIN then
            assert.equals(env, ok, err)
            local other = vim.deepcopy(env)
            other["=C:"], other["=ExitCode"] = [[C:\elsewhere]], "00000001"
            assert.equals(envscope.signature(env), envscope.signature(other))
            assert.is_nil(envscope.signature(env):find("=C:", 1, true))
        else
            assert.is_nil(ok)
            assert.truthy(err:find("malformed environment variable '=", 1, true), err)
        end
    end)

    it("still refuses names that are not variables, naming the variable but not its value", function()
        for _, bad in ipairs({ { ["A=B"] = "1" }, { ["="] = "x" }, { [""] = "x" }, { ["=C:=x"] = "y" },
            { ["A\0"] = "1" }, { A = "secret\0" } }) do
            local ok, err = envscope.validate(bad)
            assert.is_nil(ok, vim.inspect(bad))
            assert.truthy(err:find("malformed environment variable", 1, true))
            assert.is_nil(err:find("secret", 1, true))
        end
    end)

    it("capture() never yields an entry validate() refuses; with them in this process (Windows)", function()
        if WIN then
            for k, v in pairs(CMD_ENTRIES) do uv.os_setenv(k, v) end
        end
        local cap = envscope.capture()
        if WIN then
            for k in pairs(CMD_ENTRIES) do pcall(uv.os_unsetenv, k) end
            assert.equals(CMD_ENTRIES["=C:"], cap["=C:"])
        end
        assert.equals(cap, (envscope.validate(cap)))
    end)

    it("apply() leaves the process's own entries alone; with_overlay() passes the client's to the step", function()
        if not WIN then return pending("Windows only") end
        uv.os_setenv("=Q:", [[Q:\daemon]])
        local env = envscope.capture()
        env["=Q:"] = nil
        env["=R:"] = [[R:\client]]
        local seen
        envscope.with(env, function() seen = uv.os_environ() end)
        local after = uv.os_environ()
        pcall(uv.os_unsetenv, "=Q:")
        assert.equals([[Q:\daemon]], seen["=Q:"])
        assert.is_nil(seen["=R:"])
        assert.equals([[Q:\daemon]], after["=Q:"])
        local step = envscope.with_overlay(env, { FOO = "1" })
        assert.equals([[R:\client]], step["=R:"])
        assert.equals("1", step.FOO)
    end)
end)

describe("lw build routed through an in-process daemon (§19.15)", function()
    local root, srv
    local saved_stderr, saved_raw, saved_write
    local err_lines

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        err_lines = {}
        saved_stderr, saved_raw, saved_write = io.stderr, cli._raw_write, io.write
        local buf = ""
        io.stderr = { -- luacheck: ignore 122
            write = function(_, ...)
                for _, s in ipairs({ ... }) do buf = buf .. tostring(s) end
                while buf:find("\n", 1, true) do
                    local i = buf:find("\n", 1, true)
                    err_lines[#err_lines + 1] = buf:sub(1, i - 1)
                    buf = buf:sub(i + 1)
                end
                return io.stderr
            end,
            flush = function() end,
        }
        cli._raw_write = function() end
        io.write = function() end -- luacheck: ignore 122
    end)
    after_each(function()
        io.stderr, cli._raw_write, io.write = saved_stderr, saved_raw, saved_write -- luacheck: ignore 122
        for k in pairs(CMD_ENTRIES) do pcall(uv.os_unsetenv, k) end
        pcall(uv.os_unsetenv, "PROMPT")
        require("loomworks.lock_break").requested = nil
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    local function lines_matching(pat)
        local n = {}
        for _, l in ipairs(err_lines) do if l:find(pat, 1, true) then n[#n + 1] = l end end
        return n
    end

    it("routes a build whose environment came from cmd.exe (=C:, =ExitCode, PROMPT=$P$G)", function()
        if not WIN then return pending("Windows only") end
        for k, v in pairs(CMD_ENTRIES) do uv.os_setenv(k, v) end
        uv.os_setenv("PROMPT", "$P$G")
        local code = cli._delegate_build(root, { "build", "dev" }, "used", { keepalive_ms = 1000, connect_ms = 60000 })
        assert.equals(0, code, table.concat(err_lines, "\n"))
        assert.equals(1, #lines_matching("building through the workspace daemon (pid " .. srv.pid .. ")"),
            table.concat(err_lines, "\n"))
        assert.equals(0, #lines_matching("running without it"))
    end)

    it("a declined request prints one line with the daemon's reason and runs in-process", function()
        srv.retiring = true
        local code = cli._delegate_build(root, { "build", "dev" }, "used", { keepalive_ms = 1000, connect_ms = 60000 })
        assert.is_nil(code)
        assert.same({ "lw: the workspace daemon declined the build (the daemon is retiring); running without it" },
            err_lines)
    end)

    it("--break-locks prints one line and runs in-process", function()
        require("loomworks.lock_break").requested = "ask"
        assert.is_nil(cli._delegate_build(root, { "build", "dev" }, "used"))
        assert.same({ "lw: the workspace daemon could not take the build (--break-locks runs the build in this "
            .. "process); running without it" }, err_lines)
    end)

    it("a runtime held by another lw command prints one line naming it", function()
        local st = { kind = "attached", lock = { pid = 4242, mode = "attached", command = "lw build" } }
        local reason = cli._runtime_reason(st)
        assert.truthy(reason:find("held by", 1, true), reason)
        assert.truthy(reason:find("pid 4242", 1, true), reason)
        assert.equals("it runs on OTHER, pid 7", cli._runtime_reason({ kind = "foreign", lock = { pid = 7, host = "OTHER" } }))
        -- "elsewhere" from ensure: the line, then in-process.
        assert.is_nil(cli._delegate_build(root, { "build", "dev" }, "elsewhere"))
        assert.equals(1, #err_lines)
        assert.truthy(err_lines[1]:find("^lw: the workspace daemon could not take the build %(.*%); running without it$"),
            err_lines[1])
    end)

    it("in-process mode and an explicit opt-out print nothing", function()
        assert.is_nil(cli._delegate_build(root, { "build", "dev" }, "off"))
        assert.is_nil(cli._delegate_build(root, { "build", "dev" }, nil))
        assert.same({}, err_lines)
    end)
end)

describe("the handle's rename over a file being read (Windows, §19.6)", function()
    local function nvim_reader(root, ms)
        local script = H.tmp() .. "/reader.lua"
        local f = io.open(script, "w")
        f:write(string.format([[
vim.opt.rtp:prepend(%q)
package.path = %q .. "/lua/?.lua;" .. package.path
local handle = require("loomworks.daemon.handle")
local t0 = vim.uv.now()
while vim.uv.now() - t0 < %d do handle.read(%q); vim.uv.sleep(1); vim.uv.update_time() end
]], H.REPO, H.REPO, ms, root))
        f:close()
        local h, pid = uv.spawn(vim.v.progpath, { args = { "--headless", "-u", "NONE", "-l", script } }, function() end)
        assert.is_not_nil(h, tostring(pid))
        H.track(pid)
        return h
    end

    it("rewrites survive readers hammering the handle; nothing is left behind", function()
        if not WIN then return pending("Windows only (POSIX rename replaces an open file)") end
        local root = H.workspace()
        assert.is_true(handle.write(root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = 0 }))
        local readers = { nvim_reader(root, 4000), nvim_reader(root, 4000), nvim_reader(root, 4000) }
        vim.wait(500)
        local fails, n, first = 0, 0, nil
        local t0 = uv.now()
        while uv.now() - t0 < 2500 do
            n = n + 1
            local ok, err = handle.write(root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = n })
            if not ok then fails = fails + 1; first = first or err end
            uv.update_time()
        end
        vim.wait(3000, function()
            for _, h in ipairs(readers) do if h:is_active() then return false end end
            return true
        end, 20)
        H.cleanup()
        assert.equals(0, fails, tostring(first) .. " (" .. fails .. " of " .. n .. ")")
        local rec = handle.read(root)
        assert.is_true(rec.valid)
        assert.equals(n, rec.n)
        for name in vim.fs.dir(root .. "/.nvim") do
            assert.is_nil(name:find(".tmp-", 1, true), name)
        end
    end)

    --- Make `uv.fs_rename` fail with `code` for `ms` milliseconds from its
    --- first call (a reader holding the handle open), then rename for real.
    --- The window starts at the first rename, not here: staging the file
    --- before it can take longer than `ms` on a loaded runner, and the first
    --- rename would then succeed untested (CI run 37011157980). Returns the
    --- restore function and a counter.
    local function blocked_rename(ms, code)
        local orig, t0, stat = uv.fs_rename, nil, { calls = 0 }
        uv.fs_rename = function(a, b)
            stat.calls = stat.calls + 1
            t0 = t0 or uv.hrtime()
            if (uv.hrtime() - t0) / 1e6 < ms then return nil, code .. ": operation not permitted", code end
            return orig(a, b)
        end
        return function() uv.fs_rename = orig end, stat
    end

    it("a rename a reader blocks for longer than a fraction of a second still succeeds", function()
        -- A loaded machine: readers kept the rename failing for 0.6 s (the
        -- retry used to give up after about 0.2 s and log EPERM).
        local root = H.workspace()
        assert.is_true(handle.write(root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = 1 }))
        local restore, stat = blocked_rename(600, "EPERM")
        local okp, ok, err = pcall(handle.write, root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = 2 })
        restore()
        assert.is_true(okp, tostring(ok))
        assert.is_true(ok, tostring(err))
        assert.truthy(stat.calls > 1)
        assert.equals(2, handle.read(root).n)
        for name in vim.fs.dir(root .. "/.nvim") do
            assert.is_nil(name:find(".tmp-", 1, true), name)
        end
    end)

    it("a rename that keeps failing stops within its budget, removes the staged file, keeps the handle", function()
        local root = H.workspace()
        assert.is_true(handle.write(root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = 1 }))
        local restore, stat = blocked_rename(math.huge, "EPERM")
        local t0 = uv.hrtime()
        local okp, ok, err, code = pcall(handle.write, root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = 2 },
            { budget_ms = 150 })
        local ms = (uv.hrtime() - t0) / 1e6
        restore()
        assert.is_true(okp, tostring(ok))
        assert.is_nil(ok)
        assert.truthy(tostring(err):find("EPERM", 1, true))
        assert.equals("EPERM", code)
        assert.truthy(stat.calls > 1, stat.calls)
        -- Bounded: never past the budget (plus one rename and a loaded scheduler).
        assert.truthy(ms < 150 + 1000, ms)
        assert.equals(1, handle.read(root).n)
        for name in vim.fs.dir(root .. "/.nvim") do
            assert.is_nil(name:find(".tmp-", 1, true), name)
        end
        -- Any other failure is not retried.
        restore, stat = blocked_rename(math.huge, "ENOENT")
        okp, ok = pcall(handle.write, root, { pid = 1, host = "h", endpoint = "e", protocol = 1, n = 3 })
        restore()
        assert.is_true(okp, tostring(ok))
        assert.is_nil(ok)
        assert.equals(1, stat.calls)
        assert.equals(1, handle.read(root).n)
    end)

    it("the daemon keeps retrying a rewrite readers block, so clients never keep an outdated handle", function()
        -- The rename keeps failing for 1.5 s while a client connects: more
        -- than one rewrite's own retry. The daemon used to log
        -- `could not write the handle: EPERM` and leave the handle at
        -- `clients = 0` until the next change.
        local d = H.tmp()
        trust._set_key_path(d .. "/trust.key")
        local root = H.workspace()
        local lines = {}
        local srv = server_mod.new(root, { exit = function() end, tick_ms = 60000,
            log = function(l) lines[#lines + 1] = l end })
        assert.is_true((srv:start()))
        assert.equals(0, handle.read(root).clients)
        local restore = blocked_rename(1500, "EPERM")
        local okp, perr = pcall(function()
            local conn = assert(client.session(srv.address))
            assert.is_true(vim.wait(20000, function()
                local h = handle.read(root)
                return h and h.clients == 1
            end, 20))
            conn:close()
        end)
        restore()
        srv:stop("test")
        trust._set_key_path(nil)
        assert.is_true(okp, tostring(perr))
        for _, l in ipairs(lines) do
            assert.is_nil(l:find("could not write the handle", 1, true), l)
        end
        for name in vim.fs.dir(root .. "/.nvim") do
            assert.is_nil(name:find(".tmp-", 1, true), name)
        end
    end)

    it("an unchanged record is not rewritten (every rewrite is a rename a reader can block)", function()
        local d = H.tmp()
        trust._set_key_path(d .. "/trust.key")
        local root = H.workspace()
        local srv = server_mod.new(root, { exit = function() end, tick_ms = 60000 })
        assert.is_true((srv:start()))
        local restore, stat = blocked_rename(0, "EPERM")
        local ok1 = srv:_write_handle()
        local ok2 = srv:_write_handle()
        restore()
        srv:stop("test")
        trust._set_key_path(nil)
        assert.is_true(ok1)
        assert.is_true(ok2)
        assert.equals(0, stat.calls)
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
