-- The machine-level tool cache (spec §16.43; §19.11 "Warm restarts"): per
-- module type entries with a fingerprint, reused while it matches, each type
-- written atomically when its detection finishes, an interrupted type never
-- written, and a file older releases still read.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local tc = require("loomworks.tool_cache")
local uv = vim.uv or vim.loop

local IS_WIN = vim.fn.has("win32") == 1

local function sandbox()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end

local function read(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local function names(dir)
    local out = {}
    local h = uv.fs_scandir(dir)
    while h do
        local n = uv.fs_scandir_next(h)
        if not n then break end
        out[#out + 1] = n
    end
    table.sort(out)
    return out
end

--- An injected environment: a fake PATH of directories with fake mtimes.
local function fake_env(dir, over)
    local vars = { PATH = IS_WIN and "C:\\bin;C:\\tools" or "/usr/bin:/opt/tools", PATHEXT = ".COM;.EXE" }
    local mtimes = { }
    local e = {
        dir = dir,
        is_windows = IS_WIN,
        platform = IS_WIN and "windows" or "linux",
        identity = function() return "0.1.50" end,
        getenv = function(k) return vars[k] end,
        stat = function(p)
            local m = mtimes[p]
            if m == nil then m = 1000 end
            if m == false then return nil end
            return { mtime = { sec = m, nsec = 0 } }
        end,
        now = function() return 1700000000 end,
    }
    for k, v in pairs(over or {}) do e[k] = v end
    return tc.env(e), vars, mtimes
end

--- The old reader and coverage check of the releases before step 5r
--- (cli.lua before step 5r part C), verbatim in behaviour.
local function old_read(path)
    local content = read(path)
    if not content or content == "" then return nil end
    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" or data.version ~= 1 then return nil end
    return data
end
local function old_covers(cache, needed)
    local scanned = cache and cache.scanned_types or {}
    for t in pairs(needed) do if not scanned[t] then return false end end
    return true
end
--- The old writer: rewrites only the fields it knows.
local function old_write(path, tools_by_type, scanned_types)
    local existing = old_read(path) or {}
    local tbt = existing.tools_by_type or {}
    local scanned = existing.scanned_types or {}
    for t in pairs(scanned_types) do scanned[t] = true; tbt[t] = tools_by_type[t] end
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ version = 1, timestamp = os.time(), scanned_types = scanned, tools_by_type = tbt }))
    f:close()
end

local CMAKE = { { tool_key = "ninja-gcc", tool_label = "Ninja + GCC", tool_data = { generator = "Ninja" } } }

--- A detector that counts the types it detects (synchronously).
local function counter(results)
    local seen = {}
    return seen, function(t, cb)
        seen[#seen + 1] = t
        cb(results[t])
    end
end

local function run(opts)
    local got
    tc.detect(opts, function(r) got = r end)
    assert.is_true(vim.wait(5000, function() return got ~= nil end, 5))
    return got
end

describe("tool cache fingerprint (§16.43)", function()
    local dir
    before_each(function() dir = sandbox() end)

    it("is stable for the same inputs and changes with each input", function()
        local env, vars, mtimes = fake_env(dir)
        local base = tc.fingerprints({ cmake = true, meson = true }, env)
        assert.same(base, tc.fingerprints({ cmake = true, meson = true }, env))
        assert.are_not.equal(base.cmake, base.meson) -- the module id
        local function differs(why, e2)
            local fp = tc.fingerprints({ cmake = true }, e2 or env)
            assert.are_not.equal(base.cmake, fp.cmake, why)
        end
        -- lw identity (lw_version / a dev build's source hash)
        differs("identity", (fake_env(dir, { identity = function() return "0.1.51" end })))
        differs("platform", (fake_env(dir, { platform = "macos" })))
        local saved = vars.PATH
        vars.PATH = saved .. (IS_WIN and ";C:\\new" or ":/new"); differs("PATH entry added")
        vars.PATH = saved
        if IS_WIN then
            vars.PATHEXT = ".EXE"; differs("PATHEXT"); vars.PATHEXT = ".COM;.EXE"
            -- normalized: case and separators do not matter on Windows
            vars.PATH = "c:/BIN;C:\\tools\\"
            assert.equals(base.cmake, tc.fingerprints({ cmake = true }, env).cmake)
            vars.PATH = saved
        end
        local first = IS_WIN and "c:/bin" or "/usr/bin"
        mtimes[first] = 2000; differs("a search-path directory's mtime"); mtimes[first] = nil
        mtimes[first] = false; differs("a search-path directory absent"); mtimes[first] = nil
        -- the module interface version (§8.0)
        local api = require("loomworks.api_versions")
        api.module = api.module + 1
        local ok, err = pcall(differs, "module interface version")
        api.module = api.module - 1
        assert(ok, err)
        -- unrelated inputs do not count
        vars.HOME = "/elsewhere"
        assert.equals(base.cmake, tc.fingerprints({ cmake = true }, env).cmake)
    end)
end)

describe("tool cache reuse and writing (§16.43)", function()
    local dir
    before_each(function() dir = sandbox() end)
    after_each(function() require("loomworks.io").rm_rf(dir) end)

    it("reuses a matching type, detects the others; the result omits empty types", function()
        local env = fake_env(dir)
        local seen, detect = counter({ cmake = CMAKE, meson = {} })
        local r = run({ needed = { cmake = true, meson = true }, detect_one = detect, env = env })
        assert.same({ "cmake", "meson" }, seen)
        assert.same({ cmake = CMAKE }, r)
        local seen2, detect2 = counter({})
        r = run({ needed = { cmake = true, meson = true }, detect_one = detect2, env = env })
        assert.same({}, seen2, "a warm cache detects nothing")
        assert.same({ cmake = CMAKE }, r)
        -- force (`lw tools`) detects every type
        local seen3, detect3 = counter({ cmake = CMAKE })
        run({ needed = { cmake = true, meson = true }, detect_one = detect3, env = env, force = true })
        assert.same({ "cmake", "meson" }, seen3)
    end)

    it("a mismatch reruns only that type; a global input change reruns each", function()
        local env, vars = fake_env(dir)
        local _, detect = counter({ cmake = CMAKE, meson = CMAKE })
        run({ needed = { cmake = true, meson = true }, detect_one = detect, env = env })
        -- Only cmake's entry stale (e.g. written by another lw).
        local data = vim.json.decode(read(dir .. "/tools.json"))
        data.types.cmake.fp = "0000"
        local f = assert(io.open(dir .. "/tools.json", "w")); f:write(vim.json.encode(data)); f:close()
        local seen, detect2 = counter({ cmake = CMAKE })
        run({ needed = { cmake = true, meson = true }, detect_one = detect2, env = env })
        assert.same({ "cmake" }, seen)
        -- A new directory on the search path: every type misses.
        vars.PATH = vars.PATH .. (IS_WIN and ";C:\\new" or ":/new")
        local seen3, detect3 = counter({ cmake = CMAKE, meson = CMAKE })
        run({ needed = { cmake = true, meson = true }, detect_one = detect3, env = env })
        assert.same({ "cmake", "meson" }, seen3)
        -- A missing, corrupt or other-version file is a miss for every type.
        f = assert(io.open(dir .. "/tools.json", "w")); f:write("{ torn"); f:close()
        local seen4, detect4 = counter({ cmake = CMAKE, meson = CMAKE })
        run({ needed = { cmake = true, meson = true }, detect_one = detect4, env = env })
        assert.same({ "cmake", "meson" }, seen4)
        assert.is_table(tc.read(env).types.meson, "rewritten")
    end)

    it("an interrupted type is not written; types that finished are", function()
        local env = fake_env(dir)
        -- meson's detection never finishes (the process stopped meanwhile).
        local pending
        tc.detect({ needed = { cmake = true, meson = true }, env = env, detect_one = function(t, cb)
            if t == "cmake" then cb(CMAKE) else pending = cb end
        end }, function() error("never completes") end)
        assert.is_function(pending)
        local data = tc.read(env)
        assert.same(CMAKE, data.types.cmake.tools)
        assert.is_nil(data.types.meson)
        assert.is_nil(data.scanned_types.meson)
        -- Abandoned (cancelled) between types, while cmake was detecting:
        -- cmake finished and is written; meson and qmake, after the
        -- cancellation, are never started and never written (the detector
        -- would answer them, so only the cancellation check keeps them out).
        local dir2 = sandbox()
        local env2 = fake_env(dir2)
        local abandoned = false
        local seen = {}
        local r = run({ needed = { cmake = true, meson = true, qmake = true }, env = env2,
            cancelled = function() return abandoned end,
            detect_one = function(t, cb)
                seen[#seen + 1] = t
                if t == "cmake" then abandoned = true end
                cb(CMAKE)
            end })
        assert.same({ "cmake" }, seen)
        assert.same({ cmake = CMAKE }, r)
        local d2 = tc.read(env2)
        assert.is_table(d2.types.cmake, "a type that finished after the abandonment is written")
        for _, t in ipairs({ "meson", "qmake" }) do
            assert.is_nil(d2.types[t], t)
            assert.is_nil(d2.scanned_types[t], t)
            assert.is_nil(d2.tools_by_type[t], t)
        end
    end)

    it("a type whose module is not loaded is neither reused, detected nor written", function()
        local env = fake_env(dir)
        -- An entry for it under the current fingerprint (written by another lw
        -- that had the module): not served while the module is missing here.
        local fps = tc.fingerprints({ ghost = true }, env)
        assert.is_true((tc.write({ ghost = { tools = CMAKE, fp = fps.ghost } }, env)))
        local seen, detect = counter({ cmake = CMAKE, ghost = {} })
        local r = run({ needed = { cmake = true, ghost = true }, env = env, detect_one = detect,
            detectable = function(t) return t ~= "ghost" end })
        assert.same({ "cmake" }, seen)
        assert.same({ cmake = CMAKE }, r)
        -- Its entry is left as it was (never replaced by an empty result).
        assert.same(CMAKE, tc.read(env).types.ghost.tools)
        -- A fresh cache: the missing module's type gets no entry at all, so
        -- installing the module later detects it.
        local dir2 = sandbox()
        local env2 = fake_env(dir2)
        local seen2, detect2 = counter({ cmake = CMAKE })
        run({ needed = { cmake = true, ghost = true }, env = env2, detect_one = detect2,
            detectable = function(t) return t ~= "ghost" end })
        assert.same({ "cmake" }, seen2)
        local d2 = tc.read(env2)
        assert.is_nil(d2.types.ghost)
        assert.is_nil(d2.scanned_types.ghost)
        -- Installed: now detected (and written).
        local seen3, detect3 = counter({ cmake = CMAKE, ghost = CMAKE })
        local r3 = run({ needed = { cmake = true, ghost = true }, env = env2, detect_one = detect3,
            detectable = function() return true end })
        assert.same({ "ghost" }, seen3)
        assert.same({ cmake = CMAKE, ghost = CMAKE }, r3)
    end)

    it("fingerprints that cannot be computed: every type is detected, nothing is read or written", function()
        local env = fake_env(dir)
        run({ needed = { cmake = true }, env = env, detect_one = select(2, counter({ cmake = CMAKE })) })
        local before = read(dir .. "/tools.json")
        local broken = fake_env(dir, { identity = function() error("no identity") end })
        local seen, detect = counter({ cmake = CMAKE, meson = CMAKE })
        local r = run({ needed = { cmake = true, meson = true }, env = broken, detect_one = detect })
        assert.same({ "cmake", "meson" }, seen, "the cached cmake entry is not trusted")
        assert.same({ cmake = CMAKE, meson = CMAKE }, r)
        assert.equals(before, read(dir .. "/tools.json"), "nothing written")
    end)

    it("writes through unique temporary files renamed over tools.json, leaving none", function()
        local made = {}
        local real = require("loomworks.io").write_exclusive
        local env = fake_env(dir, { write_exclusive = function(p, data)
            made[#made + 1] = p
            return real(p, data, 438)
        end })
        local _, detect = counter({ cmake = CMAKE, meson = CMAKE })
        run({ needed = { cmake = true, meson = true }, detect_one = detect, env = env })
        assert.equals(2, #made, "one write per type")
        assert.are_not.equal(made[1], made[2])
        for _, p in ipairs(made) do
            local n = p:match("[^/]+$")
            assert.is_true(tc.is_temp_name(n), n)
            assert.truthy(n:find("^tools%.json%." .. uv.os_getpid() .. "%."), n)
        end
        assert.same({ "tools.json" }, names(dir))
    end)

    it("a rename blocked on Windows is retried, then given up without a leftover", function()
        local tries, slept = 0, 0
        local env = fake_env(dir, {
            rename = function() tries = tries + 1; return nil, "EPERM: operation not permitted", "EPERM" end,
            sleep = function() slept = slept + 1 end,
        })
        local ok = tc.write({ cmake = { tools = CMAKE, fp = "x" } }, env)
        assert.is_false(ok)
        assert.equals(tc.RENAME_RETRIES, tries)
        assert.equals(tc.RENAME_RETRIES - 1, slept)
        assert.same({}, names(dir))
    end)

    it("concurrent writers of different types both land (read-modify-write per type)", function()
        local env_a = fake_env(dir)
        local env_b = fake_env(dir, { identity = function() return "0.1.50" end })
        tc.write({ cmake = { tools = CMAKE, fp = "a" } }, env_a)
        tc.write({ meson = { tools = {}, fp = "b" } }, env_b)
        local data = tc.read(env_a)
        assert.equals("a", data.types.cmake.fp)
        assert.equals("b", data.types.meson.fp)
    end)

    it("older releases read the file this release writes, and this release reads theirs", function()
        local env = fake_env(dir)
        local path = dir .. "/tools.json"
        local _, detect = counter({ cmake = CMAKE, meson = {} })
        run({ needed = { cmake = true, meson = true }, detect_one = detect, env = env })
        local old = old_read(path)
        assert.is_table(old, "version stays 1")
        assert.is_true(old_covers(old, { cmake = true, meson = true }))
        assert.same(CMAKE, old.tools_by_type.cmake)
        assert.is_nil(old.tools_by_type.meson, "an empty type has no list, as before")
        -- An older release rewrites the file (dropping the per-type entries):
        -- every type misses once here, the old fields stay readable.
        old_write(path, { typescript = { { tool_data = {} } } }, { typescript = true })
        local seen, detect2 = counter({ cmake = CMAKE, meson = {} })
        run({ needed = { cmake = true, meson = true }, detect_one = detect2, env = env })
        assert.same({ "cmake", "meson" }, seen)
        old = old_read(path)
        assert.is_true(old_covers(old, { cmake = true, meson = true, typescript = true }),
            "the older release's own type is kept")
        assert.is_table(old.tools_by_type.typescript)
    end)
end)

describe("both hosts use the fingerprint check (§16.43 'Reuse')", function()
    local cli = require("loomworks.cli")
    local trust = require("loomworks.trust")
    local H = require("tests.daemon_helpers")
    local saved = {}
    local root, cache_base

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        cache_base = sandbox()
        for _, k in ipairs({ "LOCALAPPDATA", "XDG_CACHE_HOME", "PATH" }) do saved[k] = vim.env[k] end
        vim.env.LOCALAPPDATA = cache_base
        vim.env.XDG_CACHE_HOME = cache_base
    end)
    after_each(function()
        pcall(function() require("loomworks")._core():shutdown() end)
        for _, k in ipairs({ "LOCALAPPDATA", "XDG_CACHE_HOME", "PATH" }) do vim.env[k] = saved[k] end
        cli._reset_modes()
        trust._set_key_path(nil)
    end)

    --- Load through `load` with a counting detector behind the wrapper.
    local function load_counting(load)
        local calls = {}
        local core = require("loomworks")._core()
        core._deps.detect_tools_async = function(config, _, cb)
            for t in pairs(config.projects or {}) do calls[#calls + 1] = t end
            cb({})
        end
        local ws = load()
        assert.is_table(ws, "loaded")
        assert.equals(cli._cached_detect_tools_async, core._deps.detect_tools_async, "the wrapper is installed")
        assert.equals("scanned", ws._tool_state)
        core:shutdown()
        return calls
    end

    local hosts = {
        ["in-process CLI"] = function() return (cli._load_workspace_soft(root, true)) end,
        ["workspace daemon"] = function() return (cli._daemon_build_host().load(root, {}, {})) end,
    }
    it("a project type whose module is not loaded is never written (in-process wrapper)", function()
        load_counting(hosts["in-process CLI"]) -- installs the wrapper over a counting detector
        local got
        cli._cached_detect_tools_async({ projects = { g = { type = "lwtest_no_such_module" } } }, nil,
            function(r) got = r end)
        assert.is_true(vim.wait(5000, function() return got ~= nil end, 5))
        assert.same({}, got)
        local data = tc.read()
        assert.is_nil(data and data.types and data.types.lwtest_no_such_module)
        assert.is_nil(data and data.scanned_types and data.scanned_types.lwtest_no_such_module)
    end)

    it("daemon-mode `lw tools` writes every type the daemon returned", function()
        local orig = cli._read_projection
        cli._read_projection = function()
            -- shell: a project's type; cmake: only in the daemon's build-state
            -- cache (snapshot.lua `tools` detects it too); no modules listed.
            return { _projects = { { type = "shell" } }, _modules = {},
                _tools_by_type = { cmake = CMAKE } }
        end
        local ok, err = pcall(cli.cmd_tools, root, {})
        cli._read_projection = orig
        assert.is_true(ok, tostring(err))
        local data = tc.read()
        assert.same(CMAKE, data.types.cmake.tools)
        assert.same({}, data.types.shell.tools)
    end)

    for name, load in pairs(hosts) do
        it(name .. ": detects on a cold cache, reuses a matching one, re-detects on a PATH change", function()
            assert.same({ "shell" }, load_counting(load))
            assert.is_table(tc.read().types.shell, "written per type")
            assert.same({}, load_counting(load), "warm: no detection")
            vim.env.PATH = (saved.PATH or "") .. (IS_WIN and ";" or ":") .. cache_base
            assert.same({ "shell" }, load_counting(load), "a changed search path is a miss")
        end)
    end
end)
