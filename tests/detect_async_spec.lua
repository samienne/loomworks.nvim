--- Equivalence tests for the genuinely-async tool/compiler detection paths.
---
--- The `*_async` detection functions were reimplemented to fan `--version`
--- shell-outs off the main loop via `vim.system`, instead of the old
--- "call the sync path (maybe wrapped in vim.schedule)" shims that still
--- blocked the UI on init. The contract is that the async result is
--- byte-for-byte identical to the sync one: same fields, same dedup, same
--- sort order. These tests pin that by driving both paths over the same
--- stubbed PATH + `--version` output and deep-comparing the results.
---
--- Stub conventions mirror the existing suite: the sync path reads
--- `vim.fn.system` + `vim.v.shell_error`; the async path reads `vim.system`
--- (callback form) and is unblocked by a synchronous `vim.schedule` stub.

--- Save/restore globals around a function (dotted paths into _G).
local function with_stubs(stubs, fn)
    local saved = {}
    for path, value in pairs(stubs) do
        local parts = {}
        for p in string.gmatch(path, "[^%.]+") do parts[#parts + 1] = p end
        local tbl = _G
        for i = 1, #parts - 1 do tbl = tbl[parts[i]] end
        local key = parts[#parts]
        saved[path] = { tbl = tbl, key = key, prev = tbl[key] }
        tbl[key] = value
    end
    local ok, err = pcall(fn)
    for _, s in pairs(saved) do s.tbl[s.key] = s.prev end
    if not ok then error(err) end
end

-- Scenario shared by both suites: gcc + clang both present on PATH under
-- their plain (unversioned) names, each in /usr/bin. Compiler existence is
-- resolved through `cpp._path_index` (the cached PATH executable index) rather
-- than `vim.fn.executable`/`exepath` — so the tests seed that index directly.
local PLAIN = { gcc = true, ["g++"] = true, clang = true, ["clang++"] = true }
local function plain_index()
    local index = {}
    for name in pairs(PLAIN) do index[name] = "/usr/bin/" .. name end
    return index
end
local function exepath(name)
    if PLAIN[name] then return "/usr/bin/" .. name end
    return ""
end
local function executable(name)
    return PLAIN[name] and 1 or 0
end
local function version_for(path)
    if path:match("clang") then
        return "clang version 18.1.7\n"
    end
    return "g++ (Ubuntu 13.2.0-1) 13.2.0\nFree Software Foundation, Inc.\n"
end

--- vim.system stub (callback form) returning canned `--version` output.
local function system_cb(cmd, _opts, cb)
    local out = version_for(cmd[1])
    cb({ code = 0, stdout = out })
    return { wait = function() return { code = 0, stdout = out } end }
end

describe("cpp_compilers.detect_async", function()
    package.loaded["loomworks.cpp_compilers"] = nil
    local cpp = require("loomworks.cpp_compilers")

    it("yields the same array as detect()", function()
        -- Sync detect() over the scenario.
        cpp.clear_cache()
        cpp._path_index = plain_index()
        local sync_result
        with_stubs({
            ["vim.fn.system"] = function(cmd) return version_for(cmd[1]) end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            sync_result = cpp.detect()
        end)

        -- Async detect_async() from a clean cache over the same scenario.
        cpp.clear_cache()
        cpp._path_index = plain_index()
        local async_result
        with_stubs({
            ["vim.system"] = system_cb,
            ["vim.schedule"] = function(fn) fn() end,
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            cpp.detect_async(function(r) async_result = r end)
        end)
        cpp.clear_cache()

        assert.is_not_nil(sync_result)
        assert.is_not_nil(async_result)
        -- Sanity: the scenario actually detected both compilers.
        assert.equals(2, #sync_result)
        assert.same(sync_result, async_result)
    end)

    it("short-circuits to the shared cache when already populated", function()
        cpp.clear_cache()
        cpp._path_index = plain_index()
        with_stubs({
            ["vim.fn.system"] = function(cmd) return version_for(cmd[1]) end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            cpp.detect()  -- populate M._cached
        end)

        -- With the cache warm, detect_async must return it WITHOUT any probe
        -- (vim.system left unstubbed here — a call would error the scenario).
        local got
        cpp.detect_async(function(r) got = r end)
        assert.is_not_nil(got)
        assert.equals(2, #got)
        cpp.clear_cache()
    end)
end)

describe("meson.detect_tools_async", function()
    local meson = require("loomworks.modules.meson")

    -- Non-Windows so only the GNU-compiler tool path runs (deterministic
    -- across CI hosts); meson resolves directly off PATH.
    local function has(feature)
        if feature == "win32" then return 0 end
        return 0
    end
    local function exepath_meson(name)
        if name == "meson" then return "/usr/bin/meson" end
        return exepath(name)
    end

    it("yields the same array as detect_tools()", function()
        local cpp = require("loomworks.cpp_compilers")

        cpp.clear_cache()
        cpp._path_index = plain_index()
        local sync_tools
        with_stubs({
            ["vim.fn.has"] = has,
            ["vim.fn.executable"] = executable,
            ["vim.fn.exepath"] = exepath_meson,
            ["vim.fn.system"] = function(cmd) return version_for(cmd[1]) end,
            ["vim.v"] = { shell_error = 0 },
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            sync_tools = meson.detect_tools()
        end)

        cpp.clear_cache()
        cpp._path_index = plain_index()
        local async_tools
        with_stubs({
            ["vim.fn.has"] = has,
            ["vim.fn.executable"] = executable,
            ["vim.fn.exepath"] = exepath_meson,
            ["vim.system"] = system_cb,
            ["vim.schedule"] = function(fn) fn() end,
            ["vim.uv.fs_stat"] = function() return nil end,
        }, function()
            meson.detect_tools_async(function(t) async_tools = t end)
        end)
        cpp.clear_cache()

        assert.is_not_nil(sync_tools)
        assert.is_not_nil(async_tools)
        assert.equals(2, #sync_tools)  -- one tool per GNU compiler
        assert.same(sync_tools, async_tools)
    end)
end)

-- Regression for "getenv must be called in a fast event context" (crash on
-- opening a meson project). When meson is resolved via the Python-interpreter
-- probe branch of find_meson_async, its SUCCESS path must return to the main
-- loop before invoking its callback — matching the failure path's
-- `vim.schedule(try_next)`. Otherwise the downstream compiler detection (which
-- legitimately reads `vim.env.PATH` / `vim.fn`) runs inside the `vim.system`
-- completion (a libuv fast-event context) and throws.
describe("meson find_meson_async fast-event-context safety", function()
    local meson = require("loomworks.modules.meson")

    -- Non-Windows so only the GNU-compiler branch would run; meson is NOT on
    -- PATH, forcing the Python `-c` probe branch that owns the offending path.
    local function has(feature)
        if feature == "win32" then return 0 end
        return 0
    end
    local function exepath_no_meson(name)
        if name == "meson" then return "" end            -- force the probe branch
        if name == "python" then return "/usr/bin/python" end
        return exepath(name)
    end

    -- The only `vim.system` call reaching this stub is the Python `-c` probe
    -- (cpp.detect_async is spied below, so no `--version` shell-outs fire). It
    -- reports a valid meson path, driving find_meson_async's SUCCESS path.
    local function python_probe(_cmd, _opts, cb)
        cb({ code = 0, stdout = "/usr/bin/meson\n" })
        return { wait = function() return { code = 0, stdout = "/usr/bin/meson\n" } end }
    end

    it("invokes its callback on a scheduled tick, not inside the vim.system callback", function()
        local cpp = require("loomworks.cpp_compilers")

        -- Deferring `vim.schedule`: queue rather than run, so we can observe
        -- whether the find-meson callback fired synchronously or after a tick.
        local queue = {}
        local function defer(fn) queue[#queue + 1] = fn end
        local function flush()
            while #queue > 0 do table.remove(queue, 1)() end
        end

        -- Spy on cpp.detect_async — it is invoked at exactly the moment the
        -- find-meson callback fires. It stands in for the downstream detection
        -- that reads vim.env/vim.fn, so if it runs synchronously inside the
        -- `vim.system` completion the real crash would trigger there.
        local cpp_called = false
        local prev_detect_async = cpp.detect_async
        cpp.detect_async = function(cb) cpp_called = true; cb({}) end

        local called_synchronously, called_after_flush, final
        local ok, err = pcall(function()
            with_stubs({
                ["vim.fn.has"] = has,
                ["vim.fn.exepath"] = exepath_no_meson,
                ["vim.system"] = python_probe,
                ["vim.schedule"] = defer,
                ["vim.uv.fs_stat"] = function() return {} end,  -- meson path "exists"
            }, function()
                meson.detect_tools_async(function(t) final = t end)
                -- python_probe calls its completion inline, so by now the
                -- find-meson SUCCESS path has already run. Pre-fix it invoked
                -- `callback({out})` synchronously and cpp_called is already true
                -- (the fast-event-context violation). Post-fix it deferred via
                -- vim.schedule, so nothing has fired yet.
                called_synchronously = cpp_called
                flush()
                called_after_flush = cpp_called
            end)
        end)

        cpp.detect_async = prev_detect_async
        if not ok then error(err) end

        assert.is_false(called_synchronously,
            "find-meson success path invoked its callback synchronously inside "
            .. "the vim.system (fast-event) callback")
        assert.is_true(called_after_flush,
            "find-meson callback should fire after a scheduled main-loop tick")
        assert.is_not_nil(final)
    end)
end)
