-- `lw clean` routed through the workspace daemon, with real processes (spec
-- §19.15 "Clean", §19.17, §19.19 step 5c): the parity of every case against
-- the in-process path (same output, exit code, build-directory contents and
-- persisted cache) — a module clean, a core-performed wipe, a refused unsafe
-- path, nothing to clean, a failing step, an unknown or missing profile —
-- the delegation notice, the opt-outs, and an interrupted client during a
-- step and during a wipe (the daemon still answering meanwhile). No process
-- is left running.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local trust = require("loomworks.trust")
local proc = require("loomworks.proc")
local build_lock = require("loomworks.build_lock")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local NOTICE = "lw: cleaning through the workspace daemon (pid "

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- `s` with every spelling of each of `roots` replaced by its tag.
local function unroot(s, roots)
    for tag, root in pairs(roots) do
        local forms = { root, ((uv.fs_realpath(root) or root):gsub("\\", "/")) }
        for _, r in ipairs(forms) do
            if H.is_win then
                local i = s:lower():find(r:lower(), 1, true)
                while i do
                    s = s:sub(1, i - 1) .. tag .. s:sub(i + #r)
                    i = s:lower():find(r:lower(), 1, true)
                end
            else
                s = s:gsub(vim.pesc(r), tag)
            end
        end
    end
    return s
end

local function norm(s, roots) return unroot((s:gsub("\r\n", "\n")), roots) end

local function drop_notice(s)
    return (s:gsub("lw: cleaning through the workspace daemon %(pid %d+%)\n", ""))
end

--- The persisted build state, comparable across two roots.
local function cache_of(root, key_path, tags)
    tags = tags or { ["<ROOT>"] = root }
    local text = read(root .. "/.nvim/loomworks.cache.json")
    if not text then return nil end
    trust._set_key_path(key_path)
    local status, body = trust.verify("cache", text)
    trust._set_key_path(nil)
    assert.equals("valid", status)
    local function walk(v, k)
        if type(v) == "string" then
            if type(k) == "string" and (k:match("_at$") or k:match("^last_")) then return "<time>" end
            if k == "loomworks_hash" then return "<hash>" end
            return unroot(v, tags)
        end
        if type(v) ~= "table" then return v end
        local out = {}
        for kk, vv in pairs(v) do
            out[type(kk) == "string" and unroot(kk, tags) or kk] = walk(vv, kk)
        end
        return out
    end
    return walk(vim.json.decode(body))
end

--- A directory's tree (relative path → content, "<dir>" for a directory),
--- or {} when it does not exist.
local function tree_of(dir)
    local out = {}
    local function walk(d, rel)
        local h = uv.fs_scandir(d)
        while h do
            local name = uv.fs_scandir_next(h)
            if not name then break end
            local p, r = d .. "/" .. name, (rel and (rel .. "/") or "") .. name
            local st = uv.fs_lstat(p)
            if st and st.type == "directory" then out[r] = "<dir>"; walk(p, r)
            else out[r] = read(p) end
        end
    end
    walk(dir)
    return out
end

describe("lw clean through the workspace daemon (real processes)", function()
    local env
    local roots = {}

    --- A workspace with `app` (configure/build/clean run the STEP script)
    --- and `lib` (no clean_cmd: a core-performed wipe), and a profile `dev`
    --- created by lw itself. `lib_dir`: lib's build directory (default under
    --- the root).
    local function workspace(lib_dir)
        local root = H.tmp()
        roots[#roots + 1] = root
        for _, d in ipairs({ "app", "lib", ".nvim" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
        local step = root .. "/step.lua"
        write(step, H.STEP)
        local nv = (vim.v.progpath:gsub("\\", "/"))
        local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
        write(root .. "/loomworks.json", vim.json.encode({
            projects = {
                app = { path = "app", shell = { build_dir = "${workspace_root}/out/app/${variant}", configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                    clean_cmd = cmd("clean"),
                    configurations = { Debug = { build_dir = "${workspace_root}/out/app/Debug" } } } },
                lib = { path = "lib", shell = { build_dir = lib_dir or "${workspace_root}/out/lib/${variant}", configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                    configurations = { Debug = { build_dir = lib_dir or "${workspace_root}/out/lib/Debug" } } } },
            },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
        }))
        local r = H.lw({ "--no-input", "--no-daemon", "profile", "create", "dev" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr)
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
    --- Build in-process, then give the build directories content (the STEP
    --- script creates none).
    local function build(root, lib_dir)
        local r = lw(root, { "--no-input", "--no-daemon", "build", "dev" })
        assert.equals(0, r.code, r.stderr)
        for _, d in ipairs({ root .. "/out/app/Debug", lib_dir or (root .. "/out/lib/Debug") }) do
            vim.fn.mkdir(d .. "/obj", "p")
            write(d .. "/obj/a.o", "a")
            write(d .. "/out.bin", "bin")
        end
    end
    before_each(function()
        env = H.env({ LOOMWORKS_RUNTIME = "daemon" })
    end)
    after_each(function()
        for _, root in ipairs(roots) do H.track_root(root) end
        H.cleanup()
        roots = {}
    end)

    --- Run `args` in-process in `a` and routed in `b`; assert the parity.
    --- Returns the routed result.
    local function parity(a, b, args, extra, tags_a, tags_b, expect_routed)
        local full = { "--no-input" }
        vim.list_extend(full, args)
        local ra = lw(a, { "--no-daemon", unpack(full) }, extra)
        local rb = lw(b, full, extra)
        local what = table.concat(args, " ") .. " " .. vim.inspect(extra or {})
        tags_a = tags_a or { ["<ROOT>"] = a }
        tags_b = tags_b or { ["<ROOT>"] = b }
        assert.equals(ra.code, rb.code, what .. "\n" .. ra.stderr .. "\n---\n" .. rb.stderr)
        assert.equals(norm(ra.stdout, tags_a), norm(rb.stdout, tags_b), what)
        assert.equals(norm(ra.stderr, tags_a), drop_notice(norm(rb.stderr, tags_b)), what)
        assert.is_nil(ra.stderr:find(NOTICE, 1, true), what)
        assert.equals(expect_routed, rb.stderr:find(NOTICE, 1, true) ~= nil, what .. "\n" .. rb.stderr)
        assert.same(cache_of(a, env.data .. "/trust.key", tags_a), cache_of(b, env.data .. "/trust.key", tags_b), what)
        assert.same(tree_of(a .. "/out"), tree_of(b .. "/out"), what)
        return rb
    end

    it("every case: the same output, exit code, build directories and cache as in-process (§19.17)", function()
        local a, b = workspace(), workspace()
        -- Nothing to clean (never built): refused before any lock.
        parity(a, b, { "clean", "dev" }, nil, nil, nil, false)
        -- An unknown profile, an out-of-range number: refused by the resolution.
        parity(a, b, { "clean", "zzz" }, nil, nil, nil, false)
        parity(a, b, { "clean", "9" }, nil, nil, nil, false)
        build(a); build(b)
        -- A failing step: its line and exit code; the wipe after it not run.
        local f = parity(a, b, { "clean", "dev" }, { LW_TEST_FAIL = "clean" }, nil, nil, true)
        assert.equals(3, f.code)
        assert.truthy(f.stderr:find("lw: clean failed (exit 3): app: clean Debug", 1, true), f.stderr)
        assert.equals("bin", read(b .. "/out/lib/Debug/out.bin"))
        -- The module clean and the wipe.
        local ok = parity(a, b, { "clean", "dev" }, nil, nil, nil, true)
        assert.equals(0, ok.code, ok.stderr)
        assert.truthy(ok.stdout:find("cleaning profile: dev", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("==> [clean] app: clean Debug", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("step clean", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("==> [clean] lib: clean Debug", 1, true), ok.stdout)
        assert.truthy(ok.stdout:find("CLEAN OK: dev", 1, true), ok.stdout)
        assert.is_nil(uv.fs_lstat(b .. "/out/lib/Debug"))
        assert.equals("bin", read(b .. "/out/app/Debug/out.bin"))
        -- The profile by number; a missing profile (refused non-interactively).
        parity(a, b, { "clean", "1" }, nil, nil, nil, true)
        local m = parity(a, b, { "clean" }, nil, nil, nil, false)
        assert.truthy(m.stderr:find("lw: no profile specified", 1, true), m.stderr)
    end)

    it("an unsafe wipe path: refused with the in-process line, nothing removed, both ways", function()
        local oa, ob = H.tmp() .. "/outside", H.tmp() .. "/outside"
        local a, b = workspace((oa:gsub("\\", "/"))), workspace((ob:gsub("\\", "/")))
        build(a, oa); build(b, ob)
        local r = parity(a, b, { "clean", "dev" }, nil, { ["<ROOT>"] = a, ["<OUT>"] = oa },
            { ["<ROOT>"] = b, ["<OUT>"] = ob }, true)
        assert.equals(1, r.code)
        assert.truthy(r.stderr:find("lw: clean refused: unsafe build directory ", 1, true), r.stderr)
        assert.same(tree_of(oa), tree_of(ob))
        assert.equals("bin", read(ob .. "/out.bin"))
    end)

    it("the opt-outs stay in-process without a daemon line; --break-locks says so", function()
        local root = workspace()
        build(root)
        for _, case in ipairs({
            { { "--no-daemon" } },
            { {}, { LOOMWORKS_NO_DAEMON = "1" } },
            { {}, { CI = "true" } },
            { {}, { LOOMWORKS_RUNTIME = "in-process" } },
            { { "--break-locks" }, nil, "--break-locks runs the clean in this process" },
        }) do
            local args = { "--no-input", "clean", "dev" }
            vim.list_extend(args, case[1])
            local x = lw(root, args, case[2])
            assert.equals(0, x.code, x.stderr)
            assert.is_nil(x.stderr:find("cleaning through the workspace daemon", 1, true), vim.inspect(case))
            local _, fallbacks = x.stderr:gsub("running without it", "")
            assert.equals(case[3] and 1 or 0, fallbacks, x.stderr)
            if case[3] then
                assert.truthy(x.stderr:find("lw: the workspace daemon could not take the clean ("
                    .. case[3] .. "); running without it", 1, true), x.stderr)
            end
            assert.truthy(x.stdout:find("CLEAN OK: dev", 1, true), x.stdout)
        end
        local r = lw(root, { "--no-input", "clean", "dev" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find(NOTICE, 1, true) == 1, r.stderr)
    end)

    it("an interrupted client during a step: step killed, locks released, nothing removed, next clean OK", function()
        local root = workspace()
        build(root)
        local pidfile = H.tmp() .. "/pid"
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        e.vars.LW_TEST_SLEEP = "60000"
        e.vars.LW_TEST_PIDFILE = pidfile
        local c = H.lw_start({ "--no-input", "clean", "dev" }, { env = e, cwd = root })
        local ok = vim.wait(60000, function() return read(pidfile .. ".clean") ~= nil end, 20)
        if not ok then c.kill(); c.wait(5000) end
        assert.is_true(ok, c.stderr())
        H.track_root(root)
        local spid = tonumber(read(pidfile .. ".clean"))
        local sst = proc.start_time(spid)
        H.track(spid, sst)
        assert.truthy(c.stderr():find(NOTICE, 1, true), c.stderr())
        c.kill(H.is_win and "sigkill" or "sigint")
        assert.is_true(c.wait(30000))
        assert.is_true(c.code ~= 0)
        assert.is_true(vim.wait(15000, function() return proc.alive(spid, sst) ~= true end, 20))
        for _, p in ipairs({ "app", "lib" }) do
            local bd = root .. "/out/" .. p .. "/Debug"
            assert.is_true(vim.wait(10000, function() return build_lock.read(bd) == nil end, 20), bd)
        end
        -- The wipe after the cancelled step never ran.
        assert.equals("bin", read(root .. "/out/lib/Debug/out.bin"))
        local again = lw(root, { "--no-input", "clean", "dev" })
        assert.equals(0, again.code, again.stderr)
        assert.truthy(again.stderr:find(NOTICE, 1, true), again.stderr)
        assert.truthy(again.stdout:find("CLEAN OK: dev", 1, true), again.stdout)
    end)

    it("an interrupted client during a wipe: the daemon answers meanwhile, locks released, next clean OK", function()
        local root = workspace()
        build(root)
        -- A large tree, so the wipe runs a while.
        local libdir = root .. "/out/lib/Debug"
        for i = 1, 1500 do
            local d = libdir .. "/d" .. i
            uv.fs_mkdir(d, 493)
            for j = 1, 4 do write(d .. "/f" .. j, "x") end
        end
        local c = H.lw_start({ "--no-input", "clean", "dev" }, { env = env, cwd = root })
        -- The wipe started: lib's tree shrinks.
        local started = vim.wait(60000, function()
            return c.stdout():find("==> [clean] lib", 1, true) ~= nil
        end, 5)
        if not started then c.kill(); c.wait(5000) end
        assert.is_true(started, c.stderr())
        H.track_root(root)
        -- The daemon's endpoint is served while the wipe runs.
        local st = lw(root, { "daemon", "status" })
        assert.equals(0, st.code, st.stderr)
        c.kill(H.is_win and "sigkill" or "sigint")
        assert.is_true(c.wait(30000))
        for _, p in ipairs({ "app", "lib" }) do
            local bd = root .. "/out/" .. p .. "/Debug"
            assert.is_true(vim.wait(30000, function() return build_lock.read(bd) == nil end, 20), bd)
        end
        local again = lw(root, { "--no-input", "clean", "dev" })
        assert.truthy(again.code == 0 or again.stderr:find("nothing to clean", 1, true), again.stderr)
        assert.is_nil(uv.fs_lstat(libdir))
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
