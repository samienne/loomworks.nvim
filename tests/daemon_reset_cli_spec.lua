-- `lw reset` routed through the workspace daemon, with real processes (spec
-- §19.15 "Reset", §19.17, §19.19 step 5d): the parity of every case against
-- the in-process path (same output, exit code, build-directory contents and
-- persisted cache) — a profile reset, a directory shared with another profile
-- kept, `--all` with an orphaned directory, nothing to reset, `-y`, a
-- confirmed and a declined prompt, a non-interactive refusal without `-y`, an
-- unknown or missing profile — plus a plan changed between the listing and
-- the confirmation (refused, nothing removed), a second request that cannot
-- be routed (the daemon stopped while the user answered: the reset runs
-- in-process with that answer, never asking again), and an interrupted
-- client during the removal (the daemon answers meanwhile, locks released).
-- No process is left running.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local trust = require("loomworks.trust")
local build_lock = require("loomworks.build_lock")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local NOTICE = "lw: resetting through the workspace daemon (pid "
local PROMPT = "Reset profile 'dev'? [y/N]: "

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
    return (s:gsub("lw: resetting through the workspace daemon %(pid %d+%)\n", ""))
end

--- The persisted build state, comparable across two roots.
local function cache_of(root, key_path)
    local tags = { ["<ROOT>"] = root }
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

describe("lw reset through the workspace daemon (real processes)", function()
    local env
    local roots = {}

    --- `app` and `lib` (configure/build run the STEP script), and profiles
    --- created by lw itself: `dev` (app, lib) and `libonly` (lib: shares
    --- dev's lib unit, so a reset of dev keeps lib's directory).
    local function workspace()
        local root = H.tmp()
        roots[#roots + 1] = root
        for _, d in ipairs({ "app", "lib", ".nvim" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
        local step = root .. "/step.lua"
        write(step, H.STEP)
        local nv = (vim.v.progpath:gsub("\\", "/"))
        local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
        local function project(p)
            return { path = p, shell = { build_dir = "${workspace_root}/out/" .. p .. "/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"),
                configurations = { Debug = { build_dir = "${workspace_root}/out/" .. p .. "/Debug" } } } }
        end
        write(root .. "/loomworks.json", vim.json.encode({
            projects = { app = project("app"), lib = project("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" }, libonly = { lib = "Debug" } },
        }))
        for _, p in ipairs({ "dev", "libonly" }) do
            local r = H.lw({ "--no-input", "--no-daemon", "profile", "create", p }, { env = env, cwd = root })
            assert.equals(0, r.code, r.stderr)
        end
        return root
    end
    local function lw(root, args, extra, stdin)
        local e = env
        if extra then
            e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
            for k, v in pairs(extra) do e.vars[k] = v or nil end
        end
        return H.lw(args, { env = e, cwd = root, stdin = stdin })
    end
    --- Build `profile` in-process, then give its build directories content.
    local function build(root, profile)
        local r = lw(root, { "--no-input", "--no-daemon", "build", profile or "dev" })
        assert.equals(0, r.code, r.stderr)
        for _, p in ipairs({ "app", "lib" }) do
            local d = root .. "/out/" .. p .. "/Debug"
            vim.fn.mkdir(d .. "/obj", "p")
            write(d .. "/obj/a.o", "a")
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
    local function parity(a, b, args, expect_routed, extra, stdin)
        local full = {}
        vim.list_extend(full, args)
        local ra = lw(a, { "--no-daemon", unpack(full) }, extra, stdin)
        local rb = lw(b, full, extra, stdin)
        local what = table.concat(args, " ")
        local ta, tb = { ["<ROOT>"] = a }, { ["<ROOT>"] = b }
        assert.equals(ra.code, rb.code, what .. "\n" .. ra.stderr .. "\n---\n" .. rb.stderr)
        assert.equals(norm(ra.stdout, ta), norm(rb.stdout, tb), what)
        assert.equals(norm(ra.stderr, ta), drop_notice(norm(rb.stderr, tb)), what)
        assert.is_nil(ra.stderr:find(NOTICE, 1, true), what)
        assert.equals(expect_routed, rb.stderr:find(NOTICE, 1, true) ~= nil, what .. "\n" .. rb.stderr)
        assert.same(cache_of(a, env.data .. "/trust.key"), cache_of(b, env.data .. "/trust.key"), what)
        assert.same(tree_of(a .. "/out"), tree_of(b .. "/out"), what)
        return rb
    end

    it("every case: the same output, exit code, build directories and cache as in-process (§19.17)", function()
        local a, b = workspace(), workspace()
        -- Nothing to reset (never built): refused before any lock, exit 0.
        local n = parity(a, b, { "--no-input", "reset", "dev", "-y" }, false)
        assert.equals(0, n.code)
        assert.truthy(n.stdout:find("nothing to reset for profile 'dev'", 1, true), n.stdout)
        -- An unknown profile; a missing one (refused non-interactively).
        parity(a, b, { "--no-input", "reset", "zzz", "-y" }, false)
        local m = parity(a, b, { "--no-input", "reset", "-y" }, false)
        assert.truthy(m.stderr:find("lw: no profile specified", 1, true), m.stderr)
        build(a); build(b)
        -- Non-interactive without -y: the listing, then the refusal; nothing removed.
        local r = parity(a, b, { "--no-input", "reset", "dev" }, false)
        assert.equals(1, r.code)
        assert.truthy(r.stderr:find("refusing to remove build directories without confirmation", 1, true), r.stderr)
        assert.equals("a", read(b .. "/out/app/Debug/obj/a.o"))
        -- A declined prompt: aborted, nothing removed.
        local d = parity(a, b, { "reset", "dev" }, false, { LW_TEST_INTERACTIVE = "1" }, "n\n")
        assert.equals(1, d.code)
        assert.truthy(d.stdout:find(PROMPT, 1, true), d.stdout)
        assert.truthy(d.stderr:find("lw: aborted — nothing was removed", 1, true), d.stderr)
        assert.equals("a", read(b .. "/out/app/Debug/obj/a.o"))
        -- A confirmed prompt: app's directory removed, lib's kept (libonly uses it).
        local c = parity(a, b, { "reset", "dev" }, true, { LW_TEST_INTERACTIVE = "1" }, "y\n")
        assert.equals(0, c.code, c.stderr)
        local _, asked = c.stdout:gsub(vim.pesc(PROMPT), "")
        assert.equals(1, asked, c.stdout)
        assert.truthy(c.stdout:find("Will remove 1 build directory and reset profile 'dev' to unconfigured:", 1, true),
            c.stdout)
        assert.truthy(c.stdout:find("RESET OK: profile 'dev'", 1, true), c.stdout)
        assert.is_nil(uv.fs_lstat(b .. "/out/app/Debug"))
        assert.equals("a", read(b .. "/out/lib/Debug/obj/a.o"))
        -- -y: the listing comes from the task. (A reset of libonly alone has
        -- nothing to reset: dev uses its directory.)
        build(a); build(b)
        local y = parity(a, b, { "--no-input", "reset", "dev", "-y" }, true)
        assert.truthy(y.stdout:find("Will remove 1 build directory and reset profile 'dev' to unconfigured:", 1,
            true), y.stdout)
        local l = parity(a, b, { "--no-input", "reset", "libonly", "-y" }, false)
        assert.truthy(l.stdout:find("nothing to reset for profile 'libonly'", 1, true), l.stdout)
        -- --all with an orphaned directory: lib's project removed from the
        -- configuration leaves its built directory orphaned.
        build(a); build(b)
        -- (The configuration changes below are made with no daemon running.)
        H.track_root(b)
        assert.equals(0, H.stop_daemon(b, env).code)
        for _, root in ipairs({ a, b }) do
            local cfg = vim.json.decode(read(root .. "/loomworks.json"))
            vim.fn.mkdir(root .. "/out/orphan", "p")
            write(root .. "/out/orphan/x", "x")
            cfg.projects.extra = { path = "app", shell = { build_dir = "${workspace_root}/out/orphan",
                configure_cmd = cfg.projects.app.shell.configure_cmd, build_cmd = cfg.projects.app.shell.build_cmd,
                configurations = { Debug = { build_dir = "${workspace_root}/out/orphan" } } } }
            cfg.configuration_sets.extra = { extra = "Debug" }
            write(root .. "/loomworks.json", vim.json.encode(cfg))
            local p = lw(root, { "--no-input", "--no-daemon", "profile", "create", "extra" })
            assert.equals(0, p.code, p.stderr)
            assert.equals(0, lw(root, { "--no-input", "--no-daemon", "build", "extra" }).code)
            cfg.projects.extra = nil
            cfg.configuration_sets.extra = nil
            write(root .. "/loomworks.json", vim.json.encode(cfg))
        end
        local all = parity(a, b, { "--no-input", "reset", "--all", "-y" }, true)
        assert.equals(0, all.code, all.stderr)
        assert.truthy(all.stdout:find("RESET OK: the whole workspace", 1, true), all.stdout)
        assert.is_nil(uv.fs_lstat(b .. "/out/orphan"))
        assert.is_nil(uv.fs_lstat(b .. "/out/lib/Debug"))
    end)

    it("a plan changed between the listing and the confirmation is refused, nothing removed", function()
        local root = workspace()
        build(root)
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        e.vars.LW_TEST_INTERACTIVE = "1"
        local c = H.lw_start({ "reset", "dev" }, { env = e, cwd = root, stdin = true })
        local asked = vim.wait(60000, function() return c.stdout():find(PROMPT, 1, true) ~= nil end, 10)
        if not asked then c.kill(); c.wait(5000) end
        assert.is_true(asked, c.stderr() .. c.stdout())
        H.track_root(root)
        assert.truthy(c.stdout():find("Will remove 1 build directory and reset profile 'dev'", 1, true), c.stdout())
        -- Meanwhile app's directory goes (removed out of band): the removal
        -- set differs from the one listed.
        vim.fn.delete(root .. "/out/app/Debug", "rf")
        c.write("y\n")
        c.close_stdin()
        assert.is_true(c.wait(60000))
        assert.equals(1, c.code)
        assert.truthy(c.stderr():find("lw: the build directories to reset changed since they were listed — run lw reset again",
            1, true), c.stderr())
        assert.is_nil(c.stderr():find(NOTICE, 1, true), c.stderr())
        assert.equals("a", read(root .. "/out/lib/Debug/obj/a.o"))
        assert.is_nil(build_lock.read(root .. "/out/lib/Debug"))
    end)

    it("the daemon stopped while the user answered: the reset runs in-process with that answer", function()
        local root = workspace()
        build(root)
        local e = { vars = vim.deepcopy(env.vars), data = env.data, config = env.config }
        e.vars.LW_TEST_INTERACTIVE = "1"
        local c = H.lw_start({ "reset", "dev" }, { env = e, cwd = root, stdin = true })
        local asked = vim.wait(60000, function() return c.stdout():find(PROMPT, 1, true) ~= nil end, 10)
        if not asked then c.kill(); c.wait(5000) end
        assert.is_true(asked, c.stderr())
        H.track_root(root)
        assert.equals(0, H.stop_daemon(root, env).code)
        c.write("y\n")
        c.close_stdin()
        assert.is_true(c.wait(60000))
        assert.equals(0, c.code, c.stderr())
        assert.truthy(c.stderr():find("lw: the workspace daemon could not take the reset (", 1, true), c.stderr())
        assert.truthy(c.stderr():find("); running without it", 1, true), c.stderr())
        assert.is_nil(c.stderr():find(NOTICE, 1, true), c.stderr())
        local _, n = c.stdout():gsub(vim.pesc(PROMPT), "")
        assert.equals(1, n, c.stdout())
        local _, listed = c.stdout():gsub("Will remove ", "")
        assert.equals(1, listed, c.stdout())
        assert.truthy(c.stdout():find("RESET OK: profile 'dev'", 1, true), c.stdout())
        assert.is_nil(uv.fs_lstat(root .. "/out/app/Debug"))
    end)

    it("an interrupted client during the removal: the daemon answers meanwhile, locks released, next reset OK", function()
        local root = workspace()
        build(root)
        -- A large tree, so the removal runs a while.
        local appdir = root .. "/out/app/Debug"
        for i = 1, 1500 do
            local d = appdir .. "/d" .. i
            uv.fs_mkdir(d, 493)
            for j = 1, 4 do write(d .. "/f" .. j, "x") end
        end
        local c = H.lw_start({ "--no-input", "reset", "dev", "-y" }, { env = env, cwd = root })
        local started = vim.wait(60000, function() return c.stderr():find(NOTICE, 1, true) ~= nil end, 5)
        if not started then c.kill(); c.wait(5000) end
        assert.is_true(started, c.stderr())
        H.track_root(root)
        local st = lw(root, { "daemon", "status" })
        assert.equals(0, st.code, st.stderr)
        c.kill(H.is_win and "sigkill" or "sigint")
        assert.is_true(c.wait(30000))
        for _, p in ipairs({ "app" }) do
            local bd = root .. "/out/" .. p .. "/Debug"
            assert.is_true(vim.wait(30000, function() return build_lock.read(bd) == nil end, 20), bd)
        end
        local again = lw(root, { "--no-input", "reset", "dev", "-y" })
        assert.equals(0, again.code, again.stderr)
        assert.truthy(again.stdout:find("RESET OK", 1, true) or again.stdout:find("nothing to reset", 1, true),
            again.stdout)
        assert.is_nil(uv.fs_lstat(appdir))
    end)

    it("three-way parity: in-process, through a live daemon, attached (§19.1)", function()
        local roots3 = { workspace(), workspace(), workspace() }
        for _, root in ipairs(roots3) do build(root) end
        H.three_way({ roots = roots3, args = { "--no-input", "reset", "dev", "-y" }, lw = lw, env = env,
            norm = function(s, root) return norm(s, { ["<ROOT>"] = root }) end,
            state = function(root) return { cache = cache_of(root, env.data .. "/trust.key"), out = tree_of(root .. "/out") } end })
    end)
end)

describe("daemon processes", function()
    it("none is left running", function()
        H.cleanup()
        assert.equals(0, H.survivors, "a process survived the cleanup")
    end)
end)
