-- Old-host compatibility of the release bundle (spec §16.14).
--
-- The host binary fuses `lua/boot/*` + `main.lua`; the release bundle carries
-- only `lua/loomworks/**`. `lw self-update` on ANY host installs the newest
-- bundle, and hosts released before host self-update (< v0.1.29) never replace
-- themselves — so the bundle runs on hosts whose boot modules are older than it.
-- The oldest host in the wild is v0.1.2 (`BOOT_FLOOR` below). Every use of a boot
-- module or function newer than that floor must degrade (pcall / a type() guard)
-- rather than fail: v0.1.36's unguarded top-level `require("boot.help")` broke
-- every bundle-routed command on hosts older than v0.1.34.
--
-- (a) behavioral: the CLI loads, and health degrades, with boot APIs missing.
-- (b) static: a scan of lua/loomworks/** against the BOOT_API table below.

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"):gsub("\\", "/")

-- ---------------------------------------------------------------------------
-- (a) behavioral
-- ---------------------------------------------------------------------------

--- Run `fn` with the boot modules in `absent` unloadable (require raises, as on
--- a host whose bootstrap lacks them) and those in `fake` replaced; restores
--- package.loaded / package.preload afterwards.
local function with_boot(absent, fake, fn)
    local saved_loaded, saved_preload = {}, {}
    local names = {}
    for _, m in ipairs(absent) do names[#names + 1] = m end
    for m in pairs(fake) do names[#names + 1] = m end
    for _, m in ipairs(names) do
        saved_loaded[m], saved_preload[m] = package.loaded[m], package.preload[m]
        package.loaded[m] = nil
    end
    for _, m in ipairs(absent) do
        package.preload[m] = function() error("module '" .. m .. "' not found (old host)") end
    end
    for m, v in pairs(fake) do package.loaded[m] = v end
    local ok, err = pcall(fn)
    for _, m in ipairs(names) do
        package.loaded[m], package.preload[m] = saved_loaded[m], saved_preload[m]
    end
    if not ok then error(err, 0) end
end

local function capture_stdout(fn)
    local buf, rw = {}, io.write
    io.write = function(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
    local ok, err = pcall(fn)
    io.write = rw
    if not ok then error(err, 0) end
    return table.concat(buf)
end

describe("old host: the CLI loads without boot.help (host < v0.1.34)", function()
    local saved_cli
    before_each(function()
        _G.LOOMWORKS_CLI_NO_AUTORUN = true
        saved_cli = package.loaded["loomworks.cli"]
    end)
    after_each(function()
        package.loaded["loomworks.cli"] = saved_cli
    end)

    it("loads loomworks.cli and keeps a help topic for each host command", function()
        with_boot({ "boot.help" }, {}, function()
            package.loaded["loomworks.cli"] = nil
            local ok, cli = pcall(require, "loomworks.cli")
            assert.is_true(ok, tostring(cli))
            assert.is_table(cli)
            for _, k in ipairs({ "version", "install", "self-update", "bootstrap", "update" }) do
                assert.is_true(cli.has_help_topic(k), k)
            end
            local text = capture_stdout(function() assert.equals(0, cli.cmd_help("self-update")) end)
            assert.is_string(text)
            assert.matches("too old", text)
            assert.matches("Installing lw", text)
            assert.is_nil(text:find("[\128-\255]"), "fallback help must be ASCII")
        end)
    end)

    it("still uses the host's own boot.help text when the host has it", function()
        with_boot({}, { ["boot.help"] = { TOPICS = { ["self-update"] = "HOST-OWNED TEXT" } } }, function()
            package.loaded["loomworks.cli"] = nil
            local cli = require("loomworks.cli")
            local text = capture_stdout(function() cli.cmd_help("self-update") end)
            assert.matches("HOST%-OWNED TEXT", text)
        end)
    end)
end)

describe("old host: health degrades without the newer boot APIs", function()
    local suggestions = require("loomworks.suggestions")
    local saved_luaroot, saved_facts
    before_each(function()
        saved_luaroot = _G.__loomworks_luaroot
        saved_facts = suggestions._host_facts
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.2.0" -- an installed release bundle
    end)
    after_each(function()
        _G.__loomworks_luaroot = saved_luaroot
        suggestions._host_facts = saved_facts
    end)

    local PREDATES = "lw binary predates self-update — reinstall once (see README)"
    local pre_self_update_host = function()
        return { self_update = false, dev_build = false, pinned = false, fused_system_lua = false }
    end

    it("update check: a pre-0.1.26 boot.update (no resolve_channel) yields the reinstall item", function()
        -- v0.1.2's boot.update: self_update / version_info / DEFAULT_RELEASE_URL only.
        local old_update = { DEFAULT_RELEASE_URL = "https://example.invalid/releases" }
        suggestions._host_facts = pre_self_update_host
        with_boot({}, { ["boot.update"] = old_update }, function()
            local out = suggestions.update_check_provider({})
            assert.equals(1, #out)
            assert.equals(PREDATES, out[1].title)
            assert.matches("Installing lw", out[1].remedy)
        end)
    end)

    it("update check: a v0.1.26-28 boot.update (no resolve_newest_version) yields the reinstall item", function()
        local old_update = {
            DEFAULT_CHANNEL = "stable",
            resolve_channel = function() return "stable" end,
            url_override = function() return nil end,
        }
        suggestions._host_facts = pre_self_update_host
        with_boot({}, { ["boot.update"] = old_update }, function()
            local out = suggestions.update_check_provider({})
            assert.equals(1, #out)
            assert.equals(PREDATES, out[1].title)
        end)
    end)

    it("update check: stays silent for an old boot.update in a dev build", function()
        suggestions._host_facts = function() return { self_update = false, dev_build = true } end
        with_boot({}, { ["boot.update"] = {} }, function()
            assert.same({}, suggestions.update_check_provider({}))
        end)
    end)

    it("channel override: a boot.update without url_override/resolve_channel reports nothing", function()
        with_boot({}, { ["boot.update"] = {} }, function()
            assert.same({}, suggestions.channel_override_provider({}))
        end)
    end)

    it("launcher health: a host without boot.launcher_check (< v0.1.37) reports nothing", function()
        local lh = require("loomworks.launcher_health")
        with_boot({ "boot.launcher_check", "boot.repo_meta" }, {}, function()
            assert.is_nil(lh.report(ROOT))
            assert.same({}, lh.provider({ root = ROOT }))
        end)
    end)
end)

-- ---------------------------------------------------------------------------
-- (b) static guard
-- ---------------------------------------------------------------------------

-- Oldest host binary still in use. The bundle must run (degraded is fine) on it.
local BOOT_FLOOR = "0.1.2"

-- Every boot module the bundle (lua/loomworks/**) uses, with the first host
-- release that ships it, and — for modules at or below the floor — the
-- functions it calls that are NEWER than the floor, with their first release.
--
-- HOW TO UPDATE: when bundle code starts using a boot module (or a function
-- added to a boot module after BOOT_FLOOR), add it here with the first release
-- tag that has it — check with `git show v0.1.<n>:lua/boot/<module>.lua`. Then:
--   * a module newer than BOOT_FLOOR must be loaded with `pcall(require, …)`,
--     or be listed in DIRECT_OK with the reason the direct require is only
--     reachable on a host that has it;
--   * a newer function must be called only in a file that guards it with
--     `type(<mod>.<fn>) == "function"` (or `~=`), so an old host degrades.
-- Raise BOOT_FLOOR only when the oldest host in the wild is retired.
local BOOT_API = {
    ["boot.paths"] = {
        since = "0.1.0",
        -- data_dir / version_gt: 0.1.0
        fns = { installed_modules = "0.1.4", is_prerelease = "0.1.36" },
    },
    ["boot.update"] = {
        since = "0.1.0",
        -- DEFAULT_RELEASE_URL: 0.1.0; DEFAULT_CHANNEL (0.1.26) is a value, nil-safe
        fns = { resolve_channel = "0.1.26", url_override = "0.1.26", resolve_newest_version = "0.1.29" },
    },
    ["boot.verify"] = { since = "0.1.0" }, -- RELEASE_VERSION (0.1.29) is a value, nil-safe
    ["boot.modules"] = { since = "0.1.4" },
    ["boot.pin"] = { since = "0.1.6" },
    ["boot.host_update"] = { since = "0.1.29" },
    ["boot.help"] = { since = "0.1.34" },
    ["boot.repo_meta"] = { since = "0.1.36" },
    ["boot.launcher_check"] = { since = "0.1.37" },
}

-- Direct (non-pcall) requires of modules newer than BOOT_FLOOR, allowed because
-- they run only after a guard proved the host has the module. Key: "<file>|<module>".
local DIRECT_OK = {
    -- host_item: only when _host_facts found host_update.decide (facts.self_update).
    ["lua/loomworks/suggestions.lua|boot.host_update"] = true,
}

local function version_gt(a, b)
    local ai, bi = {}, {}
    for n in a:gmatch("%d+") do ai[#ai + 1] = tonumber(n) end
    for n in b:gmatch("%d+") do bi[#bi + 1] = tonumber(n) end
    for i = 1, math.max(#ai, #bi) do
        local x, y = ai[i] or 0, bi[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

--- Minimal Lua lexer: identifiers/keywords, strings (value), and punctuation.
--- Comments are dropped. Enough to find require calls and block nesting.
local function lex(src)
    local toks, i, n = {}, 1, #src
    local function long_bracket(at)
        local eq = src:match("^%[(=*)%[", at)
        if not eq then return nil end
        local close = "]" .. eq .. "]"
        local s = at + #eq + 2
        local e = src:find(close, s, true)
        return src:sub(s, (e or n + 1) - 1), (e and e + #close) or n + 1
    end
    while i <= n do
        local c = src:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif src:sub(i, i + 1) == "--" then
            local _, after = long_bracket(i + 2)
            if after then i = after else i = (src:find("\n", i, true) or n) + 1 end
        elseif c == '"' or c == "'" then
            local j, buf = i + 1, {}
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then buf[#buf + 1] = src:sub(j, j + 1); j = j + 2
                elseif d == c then break
                else buf[#buf + 1] = d; j = j + 1 end
            end
            toks[#toks + 1] = { t = "str", v = table.concat(buf) }
            i = j + 1
        elseif c == "[" and src:match("^%[=*%[", i) then
            local v, after = long_bracket(i)
            toks[#toks + 1] = { t = "str", v = v }
            i = after
        elseif c:match("[%a_]") then
            local w = src:match("^[%w_]+", i)
            toks[#toks + 1] = { t = "id", v = w }
            i = i + #w
        elseif c:match("%d") then
            local w = src:match("^[%w_%.]+", i)
            toks[#toks + 1] = { t = "num", v = w }
            i = i + #w
        else
            toks[#toks + 1] = { t = "p", v = c }
            i = i + 1
        end
    end
    return toks
end

--- Every `boot.*` require in `src`: { module, pcall = bool, fn_depth = int }.
local function boot_requires(src)
    local toks, stack, fdepth, found = lex(src), {}, 0, {}
    for k, tk in ipairs(toks) do
        if tk.t == "id" then
            local v = tk.v
            if v == "function" then stack[#stack + 1] = "function"; fdepth = fdepth + 1
            elseif v == "do" or v == "if" or v == "repeat" then stack[#stack + 1] = v
            elseif v == "end" or v == "until" then
                if table.remove(stack) == "function" then fdepth = fdepth - 1 end
            elseif v == "require" then
                local a, b = toks[k + 1], toks[k + 2]
                local arg = (a and a.t == "str") and a
                    or ((a and a.v == "(" and b and b.t == "str") and b or nil)
                if arg and arg.v:match("^boot%.") then
                    found[#found + 1] = { module = arg.v, pcall = false, fn_depth = fdepth }
                end
                -- pcall(require, "boot.x")
                local p1, p2, s = toks[k - 2], toks[k - 1], toks[k + 2]
                if p1 and p1.v == "pcall" and p2 and p2.v == "(" and a and a.v == ","
                    and s and s.t == "str" and s.v:match("^boot%.") then
                    found[#found + 1] = { module = s.v, pcall = true, fn_depth = fdepth }
                end
            end
        end
    end
    return found
end

local function bundle_files()
    local out = {}
    for _, p in ipairs(vim.fn.globpath(ROOT .. "/lua/loomworks", "**/*.lua", false, true)) do
        p = p:gsub("\\", "/")
        out[#out + 1] = { rel = p:sub(#ROOT + 2), path = p }
    end
    table.sort(out, function(a, b) return a.rel < b.rel end)
    return out
end

local function read(p)
    local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s
end

describe("old host: static boot-dependency guard (floor v" .. BOOT_FLOOR .. ")", function()
    it("the lexer finds top-level, nested and pcall'd requires", function()
        local r = boot_requires([=[
local a = require("boot.x")
--[==[ require("boot.comment") ]==]
local s = [[ require("boot.string") ]] .. "require('boot.q')"
local function f() return require 'boot.y' end
if a then local ok, m = pcall(require, "boot.z") end
for _, k in ipairs({}) do HELP[k] = require("boot.w").T[k] end
]=])
        assert.same({
            { module = "boot.x", pcall = false, fn_depth = 0 },
            { module = "boot.y", pcall = false, fn_depth = 1 },
            { module = "boot.z", pcall = true, fn_depth = 0 },
            { module = "boot.w", pcall = false, fn_depth = 0 },
        }, r)
    end)

    it("no boot module is required unguarded at module top level", function()
        local bad = {}
        for _, f in ipairs(bundle_files()) do
            for _, r in ipairs(boot_requires(read(f.path))) do
                if not r.pcall and r.fn_depth == 0 then
                    bad[#bad + 1] = f.rel .. ": require(\"" .. r.module .. "\")"
                end
            end
        end
        assert.same({}, bad, "a top-level require of a boot module breaks loading on a host "
            .. "that lacks it; use pcall(require, ...) or move it into a function")
    end)

    it("every boot module the bundle uses is in BOOT_API; newer-than-floor ones are guarded", function()
        local unknown, unguarded = {}, {}
        for _, f in ipairs(bundle_files()) do
            for _, r in ipairs(boot_requires(read(f.path))) do
                local api = BOOT_API[r.module]
                if not api then
                    unknown[#unknown + 1] = f.rel .. ": " .. r.module
                elseif version_gt(api.since, BOOT_FLOOR) and not r.pcall
                    and not DIRECT_OK[f.rel .. "|" .. r.module] then
                    unguarded[#unguarded + 1] = f.rel .. ": require(\"" .. r.module
                        .. "\") (host v" .. api.since .. "+)"
                end
            end
        end
        assert.same({}, unknown, "add these to BOOT_API in tests/old_host_compat_spec.lua "
            .. "with their first host release (see HOW TO UPDATE there)")
        assert.same({}, unguarded, "a boot module newer than the v" .. BOOT_FLOOR
            .. " floor must be loaded with pcall(require, ...) (or listed in DIRECT_OK)")
    end)

    it("functions newer than the floor are only called in files that type-guard them", function()
        local bad = {}
        for _, f in ipairs(bundle_files()) do
            -- Token-level (comments and strings excluded): calls `<x>.fn(` and
            -- guards `type(<x>.fn) ==/~= "function"`.
            local toks = lex(read(f.path))
            local called, guarded = {}, {}
            for k = 2, #toks - 1 do
                local tk = toks[k]
                if tk.t == "id" and toks[k - 1].v == "." then
                    if toks[k + 1].v == "(" then called[tk.v] = true end
                    local g = toks[k - 3]
                    if g and g.v == "(" and toks[k - 4] and toks[k - 4].v == "type"
                        and toks[k + 1].v == ")" and toks[k + 4] and toks[k + 4].v == "function" then
                        guarded[tk.v] = true
                    end
                end
            end
            for mod, api in pairs(BOOT_API) do
                for fn, since in pairs(api.fns or {}) do
                    if version_gt(since, BOOT_FLOOR) and called[fn] and not guarded[fn] then
                        bad[#bad + 1] = f.rel .. ": " .. mod .. "." .. fn .. " (host v" .. since .. "+)"
                    end
                end
            end
        end
        table.sort(bad)
        assert.same({}, bad, "guard with type(<mod>." .. "<fn>) == \"function\" so an older host degrades")
    end)
end)
