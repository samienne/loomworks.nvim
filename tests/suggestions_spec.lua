--- Tests for the suggestion framework and the compiler-cache provider
--- (headless §16.31), plus the `lw health` command's no-workspace path.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local suggestions = require("loomworks.suggestions")
local cpp = require("loomworks.cpp_compilers")
local h = require("tests.helpers")

local orig_lookup = cpp.lookup_path
local function set_present(present)
    cpp.lookup_path = function(name)
        if present[name] then return "/usr/bin/" .. name end
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Framework
-- ---------------------------------------------------------------------------
describe("suggestion framework", function()
    it("aggregates registered providers", function()
        local orig = suggestions._providers
        suggestions._providers = {}
        suggestions.register(function() return { { title = "a", detail = "d", remedy = "r" } } end)
        suggestions.register(function() return { { title = "b" } } end)
        local out = suggestions.collect({})
        assert.equals(2, #out)
        assert.equals("a", out[1].title)
        suggestions._providers = orig
    end)

    it("skips a provider that errors (advisory, never breaks)", function()
        local orig = suggestions._providers
        suggestions._providers = {}
        suggestions.register(function() error("boom") end)
        suggestions.register(function() return { { title = "ok" } } end)
        local out = suggestions.collect({})
        assert.equals(1, #out)
        assert.equals("ok", out[1].title)
        suggestions._providers = orig
    end)

    it("returns nothing for a nil workspace", function()
        assert.same({}, suggestions.collect(nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- Compiler-cache provider
-- ---------------------------------------------------------------------------
describe("compiler-cache suggestion provider", function()
    after_each(function() cpp.lookup_path = orig_lookup end)

    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local function make_ws(projects, cfg_sets)
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = projects,
                configuration_sets = cfg_sets or {},
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        return core:get_workspace()
    end

    it("fires for a C/C++ project with no cache on PATH", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("No compiler cache found", out[1].title)
        assert.is_nil(out[1].detail) -- terse: the explanation is `lw help cache`
        assert.matches("lw help cache", out[1].remedy, 1, true)
    end)

    it("no profiles: a cache on PATH is 'available' (INFO), never 'using'", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({ ccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.equals("ccache available (lw help cache)", out[1].title)
        assert.is_nil(out[1].title:find("using", 1, true))
        assert.is_nil(out[1].remedy) -- informational, no action to take
    end)

    it("does NOT count the affirmative info item in the actionable count", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({ ccache = true })
        -- The provider yields one passive item, but it is informational…
        assert.equals(1, #suggestions.collect(ws))
        -- …so the compact `N suggestions` count sees zero actionable items.
        assert.equals(0, suggestions.count_actionable(ws))
    end)

    it("DOES count the actionable install suggestion", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({}) -- no cache on PATH → actionable nag
        assert.equals(1, suggestions.count_actionable(ws))
    end)

    it("is silent (no info, no nag) when every C/C++ project pinned cache off, even with a cache present", function()
        local ws = make_ws({
            App = { cmake = { configurations = { Debug = { variables = { cache = "off" } },
                                                 Release = { variables = { cache = "off" } } } } },
        })
        set_present({ ccache = true })
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("is silent for a workspace with no C/C++ project", function()
        local ws = make_ws({ Web = { typescript = {} } })
        set_present({})
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("is silent when every C/C++ project pinned cache off", function()
        local ws = make_ws({
            App = { cmake = { configurations = { Debug = { variables = { cache = "off" } },
                                                 Release = { variables = { cache = "off" } } } } },
        })
        set_present({})
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    -- MSVC-style active profile under `auto` (spec §1.3.2 / §16.31).
    local GCC_TOOL_P = { compiler_id = "gcc-12", generator = "Ninja", compiler_path = "/usr/bin/g++" }
    local MSVC_TOOL = {
        compiler_id = "msvc-19.40", generator = "Ninja",
        compiler_path = "C:/VS/VC/bin/cl.exe", vcvarsall = "C:/VS/vcvarsall.bat",
    }
    --- `profiles` (optional): { [key] = tool_data } — several profiles on the
    --- same `debug` set; default one profile `debug` on `tool_data`.
    local function make_ws_with_profile(cfg_extra, tool_data, no_active, profiles)
        local prof = {}
        for key, td in pairs(profiles or { debug = tool_data }) do
            prof[key] = {
                configuration_set = "debug",
                tools = { cmake = { key = "t-" .. key, data = td } },
            }
        end
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = cfg_extra or {} } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({ profiles = prof }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        local tools = {}
        for key, td in pairs(profiles or { debug = tool_data }) do
            tools[#tools + 1] = { tool_key = "t-" .. key, tool_data = td, tool_label = key }
        end
        core._workspace._tools_by_type = { cmake = tools }
        core:remerge()
        local ws = core:get_workspace()
        ws._active_profile = (not no_active) and ws._profiles[1] or nil
        ws._active_profile_key = ws._active_profile and ws._active_profile.key or nil
        return ws
    end

    it("MSVC under auto with a cache present: one-line info 'available — not enabled for MSVC-style'", function()
        local ws = make_ws_with_profile(nil, MSVC_TOOL)
        set_present({ sccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.equals("sccache available — not enabled for MSVC-style (lw help cache)", out[1].title)
        assert.is_nil(out[1].remedy)
        assert.is_nil(out[1].detail)
        -- informational → not counted
        assert.equals(0, suggestions.count_actionable(ws))
    end)

    it("MSVC with an explicit cache policy reports 'using <tool>'", function()
        local ws = make_ws_with_profile({ configurations = { Debug = {
            overrides = { msvc = { cache = "sccache" } },
        } } }, MSVC_TOOL)
        set_present({ sccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.matches("using sccache", out[1].title)
    end)

    it("MSVC under auto with no cache: the install remedy says it must be enabled explicitly", function()
        local ws = make_ws_with_profile(nil, MSVC_TOOL)
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("suggestion", out[1].kind)
        assert.matches("then opt in", out[1].remedy, 1, true)
        assert.matches("lw help cache", out[1].remedy, 1, true)
    end)

    -- Tester case: NO active profile while every profile is MSVC-style under
    -- auto (would not use sccache) — health used to claim "using sccache".
    it("no active profile, all profiles MSVC-style under auto: 'available — not enabled', never 'using'", function()
        local ws = make_ws_with_profile(nil, nil, true,
            { debug = MSVC_TOOL, release = MSVC_TOOL })
        set_present({ sccache = true })
        assert.is_nil(ws._active_profile)
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.equals("sccache available — not enabled for MSVC-style (lw help cache)", out[1].title)
        assert.is_nil(out[1].title:find("using", 1, true))
    end)

    it("no active profile, one gcc profile would use ccache: 'using' names that profile", function()
        local ws = make_ws_with_profile(nil, nil, true,
            { gccprof = GCC_TOOL_P, msvcprof = MSVC_TOOL })
        set_present({ ccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("Compiler cache: using ccache (debug:t-gccprof)", out[1].title)
    end)

    it("no active profile, no cache on PATH: the install nag (opt-in note for MSVC-style)", function()
        local ws = make_ws_with_profile(nil, nil, true, { debug = MSVC_TOOL })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("suggestion", out[1].kind)
        assert.matches("then opt in", out[1].remedy, 1, true)
    end)

    it("no active profile, every profile resolves off: silent", function()
        local ws = make_ws_with_profile(nil, nil, true, { a = GCC_TOOL_P, b = GCC_TOOL_P })
        for _, p in ipairs(ws._profiles) do p._profile_variables = { App = { cache = "off" } } end
        set_present({ ccache = true })
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("the local-tier key changes with a NON-active profile's `cache` fill", function()
        local ws = make_ws_with_profile(nil, nil, true, { a = GCC_TOOL_P })
        local before = suggestions._local_key(ws)
        ws._profiles[1]._profile_variables = { App = { cache = "sccache" } }
        assert.are_not.equal(before, suggestions._local_key(ws))
    end)

    -- Health must agree with the active profile's Cache row: an explicit policy
    -- whose tool is missing resolves to NO launcher (status reads
    -- `Cache: ccache (not found)`), so health must not claim "using sccache"
    -- just because another launcher happens to be on PATH.
    local GCC_TOOL = { compiler_id = "gcc-12", generator = "Ninja", compiler_path = "/usr/bin/g++" }
    it("explicit cache=<tool> not found: actionable 'set but not found', never 'using' another", function()
        local ws = make_ws_with_profile({ configurations = { Debug = {
            variables = { cache = "ccache" },
        } } }, GCC_TOOL)
        set_present({ sccache = true })
        assert.equals("Cache: ccache (not found)", ws._active_profile:compiler_cache_status().text)
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("suggestion", out[1].kind)
        assert.matches("cache=ccache set but ccache not found", out[1].title, 1, true)
        assert.is_nil(out[1].title:find("using", 1, true))
        assert.matches("ccache", out[1].remedy, 1, true)
        assert.equals(1, suggestions.count_actionable(ws))
    end)

    it("active profile resolving `off` (other configurations cache) is silent, not 'using'", function()
        local ws = make_ws_with_profile({ configurations = {
            Debug = { variables = { cache = "off" } },
            Release = { variables = { cache = "ccache" } },
        } }, GCC_TOOL)
        set_present({ ccache = true })
        assert.equals("Cache: off", ws._active_profile:compiler_cache_status().text)
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("active profile with a resolved launcher reports that launcher", function()
        local ws = make_ws_with_profile({ configurations = { Debug = {
            variables = { cache = "sccache" },
        } } }, GCC_TOOL)
        set_present({ ccache = true, sccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.matches("using sccache", out[1].title, 1, true)
    end)

    it("the local-tier key changes with the active profile's `cache` fill", function()
        local ws = make_ws_with_profile(nil, GCC_TOOL)
        local before = suggestions._local_key(ws)
        ws._active_profile._profile_variables = { App = { cache = "sccache" } }
        assert.are_not.equal(before, suggestions._local_key(ws))
    end)

    it("recommends the platform-customary tool", function()
        local tool = suggestions._preferred_install_tool()
        assert.is_true(tool == "sccache" or tool == "ccache")
        local ws = make_ws({ App = { cmake = {} } })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.matches(tool, out[1].remedy)
    end)
end)

-- ---------------------------------------------------------------------------
-- Update-availability provider (health-only, network-backed)
-- ---------------------------------------------------------------------------
-- boot.update pulls in luvi-only builtins (openssl via boot.verify) and cannot
-- load under nvim/busted, but the provider requires it through `pcall(require,
-- …)` — so we inject a fake module via package.loaded. boot.paths (real
-- version_gt) DOES load under nvim, so the version comparison stays authentic.
describe("update-check suggestion provider", function()
    local update -- the injected fake, rebuilt per test
    local saved_luaroot, saved_loaded

    before_each(function()
        saved_luaroot = _G.__loomworks_luaroot
        saved_loaded = package.loaded["boot.update"]
        update = { DEFAULT_CHANNEL = "stable" }
        package.loaded["boot.update"] = update
    end)
    after_each(function()
        _G.__loomworks_luaroot = saved_luaroot
        package.loaded["boot.update"] = saved_loaded
    end)

    it("suggests an update when a newer version is on the channel", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return "0.2.0" end
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.equals("Update available", out[1].title)
        assert.matches("0%.1%.0 .+ 0%.2%.0", out[1].detail)
        assert.matches("stable channel", out[1].detail)
        assert.matches("self%-update", out[1].remedy)
    end)

    it("names the resolved channel in the detail", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "unstable" end
        update.resolve_newest_version = function() return "0.2.0-beta.1" end
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.matches("unstable channel", out[1].detail)
    end)

    it("is silent when already up to date", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.2.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return "0.2.0" end
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("treats a pre-release as older than its release (no downgrade suggestion)", function()
        -- Running the full 0.2.0 on stable; the unstable feed reports 0.2.0-rc.1,
        -- which orders BELOW 0.2.0 — must NOT suggest an "update".
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.2.0"
        update.resolve_channel = function() return "unstable" end
        update.resolve_newest_version = function() return "0.2.0-rc.1" end
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("is silent (graceful) on a network / API failure", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return nil, "fetch releases: offline" end
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("is silent for a dev/fused source with no comparable version", function()
        _G.__loomworks_luaroot = nil
        local called = false
        update.resolve_newest_version = function() called = true; return "9.9.9" end
        update.resolve_channel = function() return "stable" end
        assert.same({}, suggestions.update_check_provider({}))
        assert.is_false(called) -- never even probes the network without a version
    end)

    it("is silent for an unknown channel", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return nil, "unknown update channel" end
        update.resolve_newest_version = function() return "9.9.9" end
        assert.same({}, suggestions.update_check_provider({}))
    end)
end)

-- ---------------------------------------------------------------------------
-- Update check, lw BINARY (host) staleness: the bundle can be current while the
-- host binary is stale (an unwritable install dir, `--no-host`, a pre-self-update
-- host). The running host's facts come from the `_host_facts` seam (nil = not the
-- standalone host, e.g. the editor).
-- ---------------------------------------------------------------------------
describe("update-check provider: lw binary staleness", function()
    local update
    local saved_luaroot, saved_loaded, saved_facts

    before_each(function()
        saved_luaroot = _G.__loomworks_luaroot
        saved_loaded = package.loaded["boot.update"]
        saved_facts = suggestions._host_facts
        update = {
            DEFAULT_CHANNEL = "stable",
            resolve_channel = function() return "stable" end,
            resolve_newest_version = function() return "0.2.0" end,
        }
        package.loaded["boot.update"] = update
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.2.0" -- bundle current
    end)
    after_each(function()
        _G.__loomworks_luaroot = saved_luaroot
        package.loaded["boot.update"] = saved_loaded
        suggestions._host_facts = saved_facts
    end)

    --- A self-update-capable release host at `ver` (nil = unversioned).
    local function host(ver, extra)
        local f = { release_version = ver, self_update = true, exe = "/opt/lw/lw" }
        for k, v in pairs(extra or {}) do f[k] = v end
        return function() return f end
    end

    it("flags a host older than the newest release, bundle current", function()
        suggestions._host_facts = host("0.1.28")
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.is_not.equals("info", out[1].kind) -- actionable
        assert.equals("lw binary 0.1.28 is older than 0.2.0", out[1].title)
        assert.matches("lw self%-update", out[1].remedy)
        assert.matches("lw help self%-update", out[1].remedy)
    end)

    it("flags an unversioned release host (self-update replaces it)", function()
        suggestions._host_facts = host(nil)
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.equals("lw binary (unknown release) is older than 0.2.0", out[1].title)
        assert.matches("lw self%-update", out[1].remedy)
    end)

    it("tells a pre-self-update host to reinstall once", function()
        suggestions._host_facts = host(nil, { self_update = false })
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.equals("lw binary predates self-update — reinstall once (see README)", out[1].title)
        assert.matches("Installing lw", out[1].remedy)
    end)

    it("is silent for a host at or newer than the newest release (upgrade-only)", function()
        suggestions._host_facts = host("0.2.0")
        assert.same({}, suggestions.update_check_provider({}))
        suggestions._host_facts = host("0.2.1")
        assert.same({}, suggestions.update_check_provider({}))
        -- a pre-release orders below its release: 0.2.0 host vs 0.2.0-rc.1 feed
        update.resolve_newest_version = function() return "0.2.0-rc.1" end
        suggestions._host_facts = host("0.2.0")
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("is silent for a dev build, a pinned host, or no standalone host", function()
        suggestions._host_facts = host(nil, { dev_build = true })
        assert.same({}, suggestions.update_check_provider({}))
        suggestions._host_facts = host(nil, { self_update = false, dev_build = true })
        assert.same({}, suggestions.update_check_provider({}))
        suggestions._host_facts = host("0.1.0", { pinned = true })
        assert.same({}, suggestions.update_check_provider({}))
        suggestions._host_facts = host("0.1.0", { exe = "/repo/.nvim/cache/lw-0.1.0/lw" })
        assert.same({}, suggestions.update_check_provider({}))
        suggestions._host_facts = function() return nil end -- the editor
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("one item when bundle AND host are stale — self-update fixes both", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        suggestions._host_facts = host("0.1.0")
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.equals("Update available", out[1].title)
    end)

    it("still flags a pre-self-update host when the bundle is stale too", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        suggestions._host_facts = host(nil, { self_update = false })
        local titles = {}
        for _, s in ipairs(suggestions.update_check_provider({})) do titles[s.title] = true end
        assert.is_true(titles["Update available"])
        assert.is_true(titles["lw binary predates self-update — reinstall once (see README)"])
    end)

    it("the network key tracks the running bundle, host and channel", function()
        suggestions._host_facts = host("0.1.28")
        local k1 = suggestions._network_key()
        suggestions._host_facts = host("0.2.0")
        local k2 = suggestions._network_key()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        local k3 = suggestions._network_key()
        update.resolve_channel = function() return "unstable" end
        local k4 = suggestions._network_key()
        assert.is_string(k1)
        assert.are_not.equals(k1, k2)
        assert.are_not.equals(k2, k3)
        assert.are_not.equals(k3, k4)
    end)
end)

-- ---------------------------------------------------------------------------
-- No-passive-network guarantee: the health-only providers stay out of `collect`
-- ---------------------------------------------------------------------------
describe("passive collect never hits the network", function()
    it("runs health-only providers only via collect_health", function()
        local orig_p, orig_h = suggestions._providers, suggestions._health_providers
        local hits = 0
        suggestions._providers = {}
        suggestions._health_providers = { function()
            hits = hits + 1
            return { { title = "network-backed" } }
        end }

        -- Passive count: MUST NOT invoke the health provider.
        local passive = suggestions.collect({})
        assert.equals(0, hits)
        assert.same({}, passive)

        -- Explicit health: DOES invoke it.
        local health = suggestions.collect_health({})
        assert.equals(1, hits)
        assert.equals(1, #health)
        assert.equals("network-backed", health[1].title)

        suggestions._providers, suggestions._health_providers = orig_p, orig_h
    end)
end)

-- ---------------------------------------------------------------------------
-- Channel-override provider (health-only, network-free)
-- ---------------------------------------------------------------------------
describe("channel-override suggestion provider", function()
    local update -- injected fake (boot.update is luvi-only; see note above)
    local saved_loaded
    before_each(function()
        saved_loaded = package.loaded["boot.update"]
        update = { DEFAULT_CHANNEL = "stable" }
        package.loaded["boot.update"] = update
    end)
    after_each(function()
        package.loaded["boot.update"] = saved_loaded
    end)

    it("flags an override that supersedes a non-default channel", function()
        update.url_override = function() return "https://mirror.example/lw" end
        update.resolve_channel = function() return "unstable" end
        local out = suggestions.channel_override_provider({})
        assert.equals(1, #out)
        assert.matches("overridden", out[1].title)
        assert.matches("mirror.example", out[1].detail)
        assert.matches("unstable", out[1].detail)
    end)

    it("is silent when no override is in effect", function()
        update.url_override = function() return nil end
        update.resolve_channel = function() return "unstable" end
        assert.same({}, suggestions.channel_override_provider({}))
    end)

    it("is silent when the overridden channel is the default (ordinary mirror use)", function()
        update.url_override = function() return "https://mirror.example/lw" end
        update.resolve_channel = function() return update.DEFAULT_CHANNEL end
        assert.same({}, suggestions.channel_override_provider({}))
    end)
end)

-- ---------------------------------------------------------------------------
-- collect_health with NO workspace — the workspace-independent providers (update
-- availability, channel override) must still run; only the workspace-SCOPED ones
-- fall silent. This is the `lw health` in a plain dir regression (§16.31).
-- ---------------------------------------------------------------------------
describe("collect_health without a workspace", function()
    local update
    local saved_luaroot, saved_loaded
    before_each(function()
        saved_luaroot = _G.__loomworks_luaroot
        saved_loaded = package.loaded["boot.update"]
        update = { DEFAULT_CHANNEL = "stable" }
        package.loaded["boot.update"] = update
    end)
    after_each(function()
        _G.__loomworks_luaroot = saved_luaroot
        package.loaded["boot.update"] = saved_loaded
    end)

    it("still reports the update-availability item with a nil workspace", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return "0.2.0" end
        update.url_override = function() return nil end

        local out = suggestions.collect_health(nil)
        local titles = {}
        for _, s in ipairs(out) do titles[s.title] = true end
        assert.is_true(titles["Update available"])
    end)

    it("still reports a channel override with a nil workspace", function()
        _G.__loomworks_luaroot = nil -- no update item; isolate the override
        update.url_override = function() return "https://mirror.example/lw" end
        update.resolve_channel = function() return "unstable" end

        local out = suggestions.collect_health(nil)
        local titles = {}
        for _, s in ipairs(out) do titles[s.title] = true end
        assert.is_true(titles["Update channel overridden by release-url"])
    end)

    it("does not error on the workspace-scoped provider with a nil workspace", function()
        -- The compiler-cache provider is workspace-scoped: it must guard nil and
        -- simply contribute nothing rather than throwing.
        assert.same({}, suggestions.compiler_cache_provider(nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- lw health command (no-workspace path)
-- ---------------------------------------------------------------------------
describe("cli.cmd_health", function()
    local cli = require("loomworks.cli")

    it("exits 0 with the worktree hint when no workspace is present", function()
        -- Never probe the host's tools from a test (inventory §16.33).
        local orig = cli._probe_inventory
        cli._probe_inventory = function() return { results = {}, declared = {}, key = "k" } end
        local ok, rc = pcall(cli.cmd_health, nil)
        cli._probe_inventory = orig
        assert.is_true(ok)
        assert.equals(0, rc)
    end)
end)

-- ---------------------------------------------------------------------------
-- Cached two-tier model (§16.31): the local tier is lazily computed and
-- invalidated on input change; the network tier is refreshed only on
-- `collect_health`, TTL-throttled; the passive `collect` NEVER hits the network.
-- ---------------------------------------------------------------------------
describe("suggestion cache (two-tier)", function()
    local health_cache = require("loomworks.health_cache")

    -- In-memory io stub (read_json/write_json/ensure_dir) backing one workspace.
    local function mem_io()
        local store = {}
        return {
            store = store,
            read_json = function(path)
                local c = store[path]
                if not c then return nil, "enoent" end
                local ok, d = pcall(vim.json.decode, c)
                if ok then return d end
                return nil, "bad"
            end,
            write_json = function(path, tbl)
                local ok, enc = pcall(vim.json.encode, tbl)
                if not ok then return false, "encode" end
                store[path] = enc
                return true
            end,
            ensure_dir = function() return true end,
        }
    end

    local function fake_ws(io_dep)
        return {
            root = "/root",
            _core = { _deps = { io = io_dep } },
            _projects = {},
            _active_profile = nil,
        }
    end

    local path = health_cache.path("/root")

    -- Save/restore all injectable knobs the cache path touches.
    local saved
    before_each(function()
        saved = {
            providers = suggestions._providers,
            health = suggestions._health_providers,
            clock = suggestions._clock,
            local_key = suggestions._local_key,
            network_key = suggestions._network_key,
        }
        suggestions._network_key = function() return "n1" end
    end)
    after_each(function()
        suggestions._providers = saved.providers
        suggestions._health_providers = saved.health
        suggestions._clock = saved.clock
        suggestions._local_key = saved.local_key
        suggestions._network_key = saved.network_key
    end)

    it("first collect computes+persists the local tier and never calls network", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local local_calls, net_calls = 0, 0
        suggestions._providers = { function() local_calls = local_calls + 1; return { { title = "L" } } end }
        suggestions._health_providers = { function() net_calls = net_calls + 1; return { { title = "N" } } end }
        suggestions._local_key = function() return "k1" end
        suggestions._clock = function() return 1000 end

        local out = suggestions.collect(ws)
        assert.equals(1, local_calls)
        assert.equals(0, net_calls)          -- passive NEVER computes the network tier
        assert.equals(1, #out)
        assert.equals("L", out[1].title)

        -- Persisted: the file now holds the local tier with its key + timestamp.
        assert.is_string(io_dep.store[path])
        local data = health_cache.read(io_dep, "/root")
        assert.equals("k1", data.local_tier.key)
        assert.equals(1000, data.local_tier.computed_at)
    end)

    it("second collect reads the cache without recomputing the local tier", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local calls = 0
        suggestions._providers = { function() calls = calls + 1; return { { title = "L" } } end }
        suggestions._health_providers = {}
        suggestions._local_key = function() return "stable" end
        suggestions._clock = function() return 1000 end

        suggestions.collect(ws)
        suggestions.collect(ws)
        assert.equals(1, calls) -- computed once, then served from cache
    end)

    it("a changed invalidation key forces a local recompute", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local calls = 0
        suggestions._providers = { function() calls = calls + 1; return { { title = "L" } } end }
        suggestions._health_providers = {}
        suggestions._clock = function() return 1000 end

        suggestions._local_key = function() return "k1" end
        suggestions.collect(ws)
        assert.equals(1, calls)

        suggestions._local_key = function() return "k2" end -- inputs changed
        suggestions.collect(ws)
        assert.equals(2, calls)
    end)

    it("collect includes cached network items but never computes the network tier", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        -- Seed a cache that already carries a network tier (as a prior health run
        -- would have left it).
        health_cache.write(io_dep, "/root", {
            local_tier = { items = { { title = "L" } }, computed_at = 500, key = "seed" },
            network_tier = { items = { { title = "Update available" } }, computed_at = 500, key = "n1" },
        })
        local net_calls = 0
        suggestions._providers = { function() return { { title = "L" } } end }
        suggestions._health_providers = { function() net_calls = net_calls + 1; return {} end }
        suggestions._local_key = function() return "seed" end
        suggestions._clock = function() return 1000 end

        local titles = {}
        for _, s in ipairs(suggestions.collect(ws)) do titles[s.title] = true end
        assert.equals(0, net_calls)              -- never computed here
        assert.is_true(titles["L"])              -- local tier
        assert.is_true(titles["Update available"]) -- cached network item, surfaced
    end)

    it("collect_health refreshes both tiers and rewrites the cache", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local local_calls, net_calls = 0, 0
        suggestions._providers = { function() local_calls = local_calls + 1; return { { title = "L" } } end }
        suggestions._health_providers = { function() net_calls = net_calls + 1; return { { title = "N" } } end }
        suggestions._local_key = function() return "k1" end
        suggestions._clock = function() return 2000 end

        local out = suggestions.collect_health(ws)
        assert.equals(1, local_calls)
        assert.equals(1, net_calls)
        assert.equals(2, #out)

        local data = health_cache.read(io_dep, "/root")
        assert.equals(2000, data.local_tier.computed_at)
        assert.equals(2000, data.network_tier.computed_at)
        assert.equals("N", data.network_tier.items[1].title)
    end)

    it("throttles the network tier by TTL across back-to-back health runs", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local local_calls, net_calls = 0, 0
        suggestions._providers = { function() local_calls = local_calls + 1; return {} end }
        suggestions._health_providers = { function() net_calls = net_calls + 1; return { { title = "N" } } end }
        suggestions._local_key = function() return "k1" end

        local now = 1000
        suggestions._clock = function() return now end

        suggestions.collect_health(ws)             -- first: computes network
        assert.equals(1, net_calls)

        now = 1000 + 100                            -- within TTL: reuse
        suggestions.collect_health(ws)
        assert.equals(1, net_calls)
        assert.equals(2, local_calls)               -- local ALWAYS recomputed

        now = 1000 + suggestions.NETWORK_TTL + 1     -- past TTL: recompute
        suggestions.collect_health(ws)
        assert.equals(2, net_calls)
    end)

    it("collect drops cached network items recorded for another running version", function()
        -- After `lw self-update` the cached "update available / lw binary is
        -- older" item describes a version no longer running: never surface it.
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        health_cache.write(io_dep, "/root", {
            local_tier = { items = {}, computed_at = 500, key = "seed" },
            network_tier = { items = { { title = "lw binary 0.1.0 is older than 0.2.0" } },
                computed_at = 500, key = "old-host" },
        })
        suggestions._providers = { function() return {} end }
        suggestions._health_providers = {}
        suggestions._local_key = function() return "seed" end
        suggestions._clock = function() return 1000 end
        assert.same({}, suggestions.collect(ws))
    end)

    it("collect_health recomputes the network tier within the TTL when the running version changed", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local net_calls = 0
        suggestions._providers = { function() return {} end }
        suggestions._health_providers = { function() net_calls = net_calls + 1; return {} end }
        suggestions._local_key = function() return "k1" end
        suggestions._clock = function() return 1000 end

        suggestions.collect_health(ws)
        assert.equals(1, net_calls)
        assert.equals("n1", health_cache.read(io_dep, "/root").network_tier.key)
        suggestions.collect_health(ws)                  -- same version, within TTL
        assert.equals(1, net_calls)
        suggestions._network_key = function() return "n2" end -- self-updated since
        suggestions.collect_health(ws)
        assert.equals(2, net_calls)
    end)

    it("--force refreshes the network tier within the TTL window", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        local net_calls = 0
        suggestions._providers = { function() return {} end }
        suggestions._health_providers = { function() net_calls = net_calls + 1; return { { title = "N" } } end }
        suggestions._local_key = function() return "k1" end
        suggestions._clock = function() return 1000 end

        suggestions.collect_health(ws)
        assert.equals(1, net_calls)
        suggestions.collect_health(ws, { force = true }) -- ignore the throttle
        assert.equals(2, net_calls)
    end)

    it("recomputes (no error) when the cache file is corrupt", function()
        local io_dep = mem_io()
        io_dep.store[path] = "{ this is not valid json"
        local ws = fake_ws(io_dep)
        local calls = 0
        suggestions._providers = { function() calls = calls + 1; return { { title = "L" } } end }
        suggestions._health_providers = {}
        suggestions._local_key = function() return "k1" end
        suggestions._clock = function() return 1000 end

        local out = suggestions.collect(ws)
        assert.equals(1, calls)
        assert.equals(1, #out)
        assert.equals("L", out[1].title)
    end)

    it("excludes info items from the count even via the cached path", function()
        local io_dep = mem_io()
        local ws = fake_ws(io_dep)
        suggestions._providers = { function()
            return { { title = "affirm", kind = "info" }, { title = "nag" } }
        end }
        suggestions._health_providers = {}
        suggestions._local_key = function() return "k1" end
        suggestions._clock = function() return 1000 end

        assert.equals(2, #suggestions.collect(ws))
        assert.equals(1, suggestions.count_actionable(ws)) -- info item not counted
    end)
end)

-- ---------------------------------------------------------------------------
-- The real local-tier invalidation key reflects the workspace inputs.
-- ---------------------------------------------------------------------------
describe("local-tier invalidation key", function()
    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local function make_ws(projects)
        local files = {
            ["loomworks.json"] = h.make_config_json({ projects = projects }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        return core:get_workspace()
    end

    it("is stable for the same workspace and differs when projects differ", function()
        local ws1 = make_ws({ App = { cmake = {} } })
        local k1a = suggestions._local_key(ws1)
        local k1b = suggestions._local_key(ws1)
        assert.equals(k1a, k1b) -- deterministic

        local ws2 = make_ws({ App = { cmake = {} }, Lib = { cmake = {} } })
        assert.not_equals(k1a, suggestions._local_key(ws2))
    end)

    it("is a non-empty short hex string and tolerates a nil workspace", function()
        assert.is_string(suggestions._local_key(nil))
        assert.matches("^%x+$", suggestions._local_key(nil))
    end)
end)
