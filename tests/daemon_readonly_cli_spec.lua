-- The read-only commands on the runtime's projection, with real processes
-- (spec §19.13, §19.14): in `runtime-mode daemon` `lw status`, `profile
-- show`/`query`, `describe`, `project`/`config`/`configset`/`launch`
-- list/show and `lw tools` read the read-only projection of the daemon's
-- model (shared) or of the loopback runtime (attached) instead of loading
-- the workspace — with the same output, exit code and files as in-process
-- (three-way parity, §19.1). `lw status` shows a running task over the
-- projection. No process is left running.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- `s` with every spelling of `root` replaced by <ROOT>.
local function unroot(s, root)
    local forms = { root, ((uv.fs_realpath(root) or root):gsub("\\", "/")),
        ((uv.fs_realpath(root) or root):gsub("/", "\\")) }
    for _, r in ipairs(forms) do
        if H.is_win then
            local i = s:lower():find(r:lower(), 1, true)
            while i do
                s = s:sub(1, i - 1) .. "<ROOT>" .. s:sub(i + #r)
                i = s:lower():find(r:lower(), 1, true)
            end
        else
            s = s:gsub(vim.pesc(r), "<ROOT>")
        end
    end
    return s
end

--- Output comparable across the runtimes: the root and the workspace name
--- masked, and `lw status`'s Runtime row (it names the runtime, §19.6)
--- dropped.
local function norm(s, root)
    s = unroot((s:gsub("\r\n", "\n")), root)
    -- (The workspace name is its directory's.)
    s = s:gsub("loomworks — [^\n]-  %(<ROOT>%)", "loomworks — <NAME>  (<ROOT>)")
    return (s:gsub("Runtime[^\n]*\n", ""))
end

--- The persisted state files, comparable across roots (times masked).
local function state_of(root, key_path)
    local out = {}
    for _, f in ipairs({ "cache", "user" }) do
        local text = read(root .. "/.nvim/loomworks." .. f .. ".json")
        if text then
            trust._set_key_path(key_path)
            local status, body = trust.verify(f, text)
            trust._set_key_path(nil)
            assert.equals("valid", status, f)
            local function walk(v, k)
                if type(v) == "string" then
                    if type(k) == "string" and (k:match("_at$") or k:match("^last_")) then return "<time>" end
                    if k == "loomworks_hash" then return "<hash>" end
                    return unroot(v, root)
                end
                if type(v) ~= "table" then return v end
                local t = {}
                for kk, vv in pairs(v) do t[type(kk) == "string" and unroot(kk, root) or kk] = walk(vv, kk) end
                return t
            end
            out[f] = walk(vim.json.decode(body))
        end
    end
    return out
end

--- How many snapshots a root's runtime log records.
local function snapshots(root)
    local log = read(root .. "/.nvim/loomworks.daemon.log") or ""
    local _, n = log:gsub("snapshot %(scope all%)", "")
    return n
end

--- How many times a root's runtime log records query `name`.
local function queries(root, name)
    local log = read(root .. "/.nvim/loomworks.daemon.log") or ""
    local _, n = log:gsub("query " .. name .. " for", "")
    return n
end

local function key(p) return (tostring(p):gsub("\\", "/"):lower()) end

describe("read-only commands on the projection (§19.13, §19.14)", function()
    local env
    local roots = {}
    local trace

    --- How many reads of `root` built a projection (the CLI's
    --- LW_TEST_READ_TRACE marker).
    local function projections(root)
        local n = 0
        for line in (read(trace) or ""):gmatch("[^\n]+") do
            if key((line:gsub("%s+$", ""))) == "projection " .. key(root) then n = n + 1 end
        end
        return n
    end

    --- A workspace with two shell projects (`app` described), a set `dev`
    --- and a profile `dev`, authored in-process by lw itself.
    local function workspace()
        local root = H.tmp()
        roots[#roots + 1] = root
        for _, d in ipairs({ "app", "lib", ".nvim" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
        local step = root .. "/step.lua"
        write(step, H.STEP)
        local nv = (vim.v.progpath:gsub("\\", "/"))
        local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
        local function proj(name)
            return { path = name, shell = { build_dir = "${workspace_root}/out/" .. name .. "/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = vim.empty_dict(), Release = vim.empty_dict() } } }
        end
        write(root .. "/loomworks.json", vim.json.encode({
            projects = { app = proj("app"), lib = proj("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" }, rel = { app = "Release", lib = "Release" } },
        }))
        for _, args in ipairs({ { "profile", "create", "dev" }, { "project", "describe", "app", "The application." } }) do
            local r = H.lw({ "--no-input", "--no-daemon", unpack(args) }, { env = env, cwd = root })
            assert.equals(0, r.code, r.stderr)
        end
        return root
    end
    local function lw(root, args, extra)
        local e = env
        if extra then
            e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
            for k, v in pairs(extra) do e.vars[k] = v or nil end
        end
        return H.lw(args, { env = e, cwd = root })
    end

    before_each(function()
        trace = H.tmp() .. "/read-trace"
        env = H.env({ LOOMWORKS_RUNTIME = "daemon", LW_TEST_READ_TRACE = trace })
    end)
    after_each(function()
        for _, root in ipairs(roots) do H.track_root(root) end
        H.cleanup()
        roots = {}
    end)

    --- Three-way parity of `args` on `roots3`: only the shared daemon's read
    --- is served by a snapshot and builds a projection; the in-process and
    --- the attached (`--no-daemon`) reads are in-process (no loopback
    --- runtime, §19.1). The daemon of the shared root is started first: a
    --- read-only command never launches one, and three_way stops it after.
    local function parity(roots3, args)
        local r = lw(roots3[2], { "--no-input", "daemon", "restart" })
        assert.equals(0, r.code, r.stderr)
        local before, proj = {}, {}
        for i, root in ipairs(roots3) do before[i], proj[i] = snapshots(root), projections(root) end
        local res = H.three_way({ roots = roots3, args = args, lw = lw, env = env, routed = false,
            norm = norm, state = function(root) return state_of(root, env.data .. "/trust.key") end })
        local what = table.concat(args, " ")
        assert.equals(before[1], snapshots(roots3[1]), what .. ": in-process read a snapshot")
        assert.is_true(snapshots(roots3[2]) > before[2], what .. ": shared read no snapshot")
        assert.equals(before[3], snapshots(roots3[3]), what .. ": attached read a snapshot")
        assert.equals(proj[1], projections(roots3[1]), what .. ": in-process built a projection")
        assert.is_true(projections(roots3[2]) > proj[2], what .. ": shared built no projection")
        assert.equals(proj[3], projections(roots3[3]), what .. ": attached built a projection")
        local log = read(roots3[3] .. "/.nvim/loomworks.daemon.log") or ""
        assert.falsy(log:find("attached run of", 1, true), what .. ": a loopback runtime ran\n" .. log)
        return res
    end

    it("every read-only command family: same output, exit code and files", function()
        local roots3 = { workspace(), workspace(), workspace() }
        local r = parity(roots3, { "status" })
        assert.truthy(r.stdout:find("dev", 1, true), r.stdout)
        r = parity(roots3, { "profile", "show", "dev" })
        assert.equals(0, r.code, r.stderr)
        r = parity(roots3, { "profile", "query", "dev", "app", "build-dir" })
        assert.truthy(r.stdout:find("app/Debug", 1, true), r.stdout)
        local nq = queries(roots3[2], "profile_cache")
        r = parity(roots3, { "profile", "query", "dev", "app", "cache" })
        assert.truthy(vim.trim(r.stdout) ~= "", "an empty cache row")
        assert.equals(nq + 1, queries(roots3[2], "profile_cache"), "the daemon ran no profile_cache query")
        r = parity(roots3, { "project", "list" })
        assert.truthy(r.stdout:find("The application.", 1, true), r.stdout)
        parity(roots3, { "project", "show", "app" })
        parity(roots3, { "project", "describe", "app" })
        parity(roots3, { "config", "list" })
        parity(roots3, { "config", "show", "app", "Release" })
        parity(roots3, { "config", "get", "app", "Debug", "build_dir" })
        parity(roots3, { "configset", "list" })
        parity(roots3, { "configset", "show", "rel" })
        parity(roots3, { "launch", "list" })
        parity(roots3, { "tools" })
        -- A refusal is the same line on every runtime.
        r = parity(roots3, { "project", "show", "nope" })
        assert.equals(1, r.code)
    end)

    it("with no daemon running a read launches none and reads in-process (§19.1)", function()
        local root = workspace()
        local inspect = require("loomworks.daemon.inspect")
        assert.equals("none", inspect.state(root).kind)
        for _, args in ipairs({ { "project", "list" }, { "project", "describe", "app" },
            { "config", "list" }, { "profile", "show", "dev" }, { "launch", "list" } }) do
            local what = table.concat(args, " ")
            local inproc = lw(root, args, { LOOMWORKS_RUNTIME = "in-process" })
            local r = lw(root, { "--no-input", unpack(args) })
            assert.equals(inproc.code, r.code, what .. ": " .. r.stderr)
            assert.equals(norm(inproc.stdout, root), norm(r.stdout, root), what)
            assert.equals("none", inspect.state(root).kind, what .. ": launched a daemon")
        end
        assert.equals(0, projections(root), "a projection without a daemon")
        assert.equals(0, snapshots(root))
        -- A form that writes keeps the ensure step: it launches the daemon.
        local w = lw(root, { "--no-input", "project", "describe", "app", "Changed." })
        assert.equals(0, w.code, w.stderr)
        assert.are_not.equals("none", inspect.state(root).kind)
        H.stop_daemon(root, env)
    end)

    it("a daemon that does not answer in time: the read falls back in-process with a note", function()
        local root = workspace()
        local r = lw(root, { "--no-input", "daemon", "restart" })
        assert.equals(0, r.code, r.stderr)
        local inproc = lw(root, { "status" }, { LOOMWORKS_RUNTIME = "in-process" })
        local n = projections(root)
        local st = lw(root, { "status" }, { LW_TEST_READ_DEADLINE_MS = "500", LW_TEST_MODEL_DELAY_MS = "20000" })
        assert.equals(0, st.code, st.stderr)
        assert.truthy(st.stderr:find("did not answer in time", 1, true), st.stderr)
        assert.equals(n, projections(root))
        assert.equals(norm(inproc.stdout, root), norm(st.stdout, root))
        -- The daemon was left running (a read never stops one).
        assert.equals("live", require("loomworks.daemon.inspect").state(root).kind)
        H.stop_daemon(root, env)
    end)

    it("lw status over the projection shows the daemon's running task", function()
        local root = workspace()
        local slow = { LW_TEST_SLEEP = "20000", LW_TEST_SLEEP_STEP = "build", LW_TEST_PIDFILE = root .. "/pid" }
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        for k, v in pairs(slow) do e.vars[k] = v end
        local b = H.lw_start({ "--no-input", "build", "dev" }, { env = e, cwd = root })
        local running = vim.wait(60000, function() return uv.fs_stat(root .. "/pid.build") ~= nil end, 20)
        H.track_root(root)
        if not running then b.kill(); b.wait(5000) end
        assert.is_true(running, b.stderr())
        local n = snapshots(root)
        -- The same environment as the build (another one is declined while
        -- a build runs, and the status reads in-process).
        local st = lw(root, { "status" }, slow)
        b.kill(H.is_win and "sigkill" or "sigint")
        b.wait(30000)
        assert.equals(0, st.code, st.stderr)
        assert.truthy(st.stdout:find("build  dev", 1, true), st.stdout)
        assert.is_true(snapshots(root) > n, "no snapshot served")
        assert.is_true(projections(root) > 0, "no projection built")
        H.stop_daemon(root, env)
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
