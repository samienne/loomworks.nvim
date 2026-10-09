-- binary.channel (spec §19.16 "Channel upgrades", step 5h.5): the pinned
-- managed lw resolves the channel with `lw release query` (§16.42); a newer
-- release whose descriptor passes the pin's check (schemas equal to ours) is
-- accepted, downloaded and recorded in channel.json; the wanted managed lw is
-- the newer of the pin and the accepted release; failures (offline, an lw
-- older than the query, an incompatible release) are one note each and keep
-- the current binary. No network: the query and downloads are injected.

local channel = require("loomworks.provision.channel")
local managed = require("loomworks.provision.managed")
local binsel = require("loomworks.provision.select")
local version = require("loomworks.daemon.version")
local observer = require("loomworks.daemon.observer")

local PIN = managed.pinned_wanted()
local ASSET = PIN and PIN.asset or "lw-linux-x86_64"
local function sha(c) return string.rep(c, 64) end

local function descriptor() return require("loomworks.daemon.descriptor").describe() end

--- A `release query --json` result offering `v` (this host's asset -> `h`).
local function query_res(v, h, d, extra)
    local doc = { query = 1, channel = "unstable", channel_ignored = false, source = "origin", version = v,
        prerelease = v:find("-", 1, true) ~= nil, assets = { [ASSET] = h or sha("c") }, descriptor = d or descriptor() }
    for k, x in pairs(extra or {}) do doc[k] = x end
    return { code = 0, stdout = vim.json.encode(doc), stderr = "" }
end

local function ctx(cur, extra)
    local c = { channel = "unstable", asset = ASSET, current = cur or { version = "0.1.44", sha256 = sha("a"), asset = ASSET },
        pinned_version = "0.1.44" }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function tmpdata()
    local d = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(d, "p")
    return d
end

describe("binary.channel: weighing a query (§19.16 Channel upgrades)", function()
    it("a newer compatible release is accepted with the hash from the query", function()
        local out = channel.classify(query_res("0.1.45-beta.1", sha("d")), ctx())
        assert.equals("accepted", out.kind, out.note)
        assert.same({ sha256 = sha("d"), version = "0.1.45-beta.1", asset = ASSET, channel = "unstable" }, out.wanted)
        assert.equals("0.1.45-beta.1", out.accepted.version)
        assert.is_table(out.accepted.descriptor)
    end)

    it("the current or an older (withdrawn) release changes nothing, quietly", function()
        assert.equals("current", channel.classify(query_res("0.1.44"), ctx()).kind)
        local older = channel.classify(query_res("0.1.44-beta.9"), ctx())
        assert.equals("older", older.kind)
        assert.is_nil(older.note)
    end)

    it("a newer release without transport overlap or with other schemas is rejected with one note", function()
        local d = descriptor()
        d.transport = { min = version.PROTOCOL + 5, max = version.PROTOCOL + 6 }
        local out = channel.classify(query_res("0.2.0", nil, d), ctx())
        assert.equals("rejected", out.kind)
        assert.truthy(out.note:find("unstable offers lw v0.2.0, which this plugin cannot use (", 1, true), out.note)
        assert.truthy(out.note:find("staying on lw v0.1.44", 1, true), out.note)
        -- Schemas in either direction (the managed lw must match the plugin).
        for _, delta in ipairs({ 1, -1 }) do
            local s = version.schemas()
            local d2 = descriptor()
            d2.schemas = { user = s.user + delta, cache = s.cache }
            assert.equals("rejected", channel.classify(query_res("0.2.0", nil, d2), ctx()).kind)
        end
        -- No loomworks.Root/1.
        local d3 = descriptor()
        d3.objects = {}
        assert.equals("rejected", channel.classify(query_res("0.2.0", nil, d3), ctx()).kind)
    end)

    it("a release rejected before is not weighed again", function()
        local out = channel.classify(query_res("0.2.0"), ctx(nil, { rejected = { version = "0.2.0", why = "old" } }))
        assert.equals("rejected", out.kind)
        assert.is_true(out.again)
        assert.truthy(out.note:find("(old)", 1, true))
    end)

    it("a pinned lw older than the query command degrades to one note", function()
        local out = channel.classify({ code = 2, stdout = "", stderr = "lw: unknown command 'release' — run `lw help`\n" }, ctx())
        assert.equals("unsupported", out.kind)
        assert.truthy(out.note:find("the pinned lw v0.1.44 has no `lw release query`", 1, true), out.note)
    end)

    it("offline, a timeout, garbage or a missing asset is a failure note", function()
        local f = channel.classify({ code = 1, stdout = "", stderr = "lw: release query failed: no network\n" }, ctx())
        assert.equals("failed", f.kind)
        assert.truthy(f.note:find("could not check (lw release query failed (status 1): release query failed: no network)", 1, true), f.note)
        assert.equals("failed", channel.classify({ code = 124, signal = 9, timed_out = true }, ctx()).kind)
        assert.equals("failed", channel.classify({ code = 0, stdout = "nope" }, ctx()).kind)
        local r = query_res("0.2.0")
        local doc = vim.json.decode(r.stdout)
        doc.assets = {}
        assert.equals("failed", channel.classify({ code = 0, stdout = vim.json.encode(doc) }, ctx()).kind)
    end)

    it("a release-source override superseding the channel is said, never silent", function()
        local out = channel.classify(query_res("0.2.0", nil, nil, { channel_ignored = true, source = "override" }), ctx())
        assert.equals("accepted", out.kind)
        assert.truthy(out.override:find("supersedes binary.channel = unstable", 1, true))
        assert.truthy(channel.classify(query_res("0.1.44", nil, nil, { channel_ignored = true }), ctx()).note)
    end)

    it("runs the query with the channel, JSON, a bound, and the overrides passed through", function()
        assert.same({ "release", "query", "--channel", "stable", "--json", "--timeout", tostring(channel.QUERY_TIMEOUT_S) },
            channel.args("stable"))
        local env = channel.env({ release_url = "/mirror", data = "/d" })
        assert.equals("/mirror", env.LOOMWORKS_RELEASE_URL)
        assert.equals("/d/loomworks", env.LOOMWORKS_INSTALL_DIR)
        assert.is_nil(channel.env({ data = "/d" }).LOOMWORKS_RELEASE_URL)
    end)
end)

describe("binary.channel: channel.json and the wanted managed lw", function()
    it("applies only to a valid channel with downloads on and no development source", function()
        assert.is_false(channel.applies({}))
        assert.is_true(channel.applies({ channel = "stable" }))
        assert.is_false(channel.applies({ channel = "nightly" }))
        assert.is_false(channel.applies({ channel = "stable", download = false }))
        assert.is_false(channel.applies({ channel = "stable", source = true }))
    end)

    it("round-trips the record; a changed channel keeps the accepted release and is due at once", function()
        local data = tmpdata()
        local out = channel.classify(query_res("0.1.99", sha("e")), ctx())
        local rec = channel.record(channel.for_channel(nil, "unstable"), out, 1000)
        assert.is_true(channel.save(rec, { data = data }))
        local back = channel.load({ data = data })
        assert.equals("unstable", back.channel)
        assert.equals(1000, back.checked)
        assert.equals(sha("e"), back.accepted.sha256)
        assert.is_false(channel.due(back, "unstable", 1000 + 10))
        assert.is_true(channel.due(back, "unstable", 1000 + channel.INTERVAL_S))
        assert.is_true(channel.due(back, "stable", 1001))
        back.rejected = { version = "0.3.0", why = "x" }
        local st = channel.for_channel(back, "stable")
        assert.equals("stable", st.channel)
        assert.is_nil(st.rejected); assert.is_nil(st.checked)
        assert.equals(sha("e"), st.accepted.sha256) -- unstable -> stable keeps a newer pre-release
        vim.fn.delete(data, "rf")
    end)

    it("an unusable file is as good as none", function()
        local data = tmpdata()
        vim.fn.mkdir(data .. "/loomworks", "p")
        vim.fn.writefile({ "{ not json" }, data .. "/loomworks/channel.json")
        assert.is_nil(channel.load({ data = data }))
        vim.fn.delete(data, "rf")
    end)

    it("the wanted lw is the newer of the pin and the accepted release, never below the pin", function()
        local pin = { version = "0.1.44", assets = { ["lw-linux-x86_64"] = sha("a") } }
        local function wanted(setting, acc)
            return managed.wanted({ pinned = pin, sysname = "Linux", machine = "x86_64", setting = setting,
                channel = function() return acc end })
        end
        local newer = { sha256 = sha("b"), version = "0.1.45-beta.1", asset = "lw-linux-x86_64", channel = "unstable" }
        assert.equals(sha("b"), wanted({ channel = "unstable" }, newer).sha256)
        assert.equals(sha("a"), wanted({ channel = "unstable" },
            { sha256 = sha("b"), version = "0.1.44-beta.9", asset = "lw-linux-x86_64" }).sha256)
        assert.equals(sha("a"), wanted({}, newer).sha256) -- channel off: the pin
        assert.equals(sha("a"), wanted(nil, newer).sha256)
    end)

    it("an accepted release this plugin no longer matches falls back to the pin", function()
        local data = tmpdata()
        local d = descriptor()
        local rec = { format = 1, channel = "stable", checked = 1,
            accepted = { version = "9.0.0", asset = ASSET, sha256 = sha("f"), descriptor = d } }
        assert.is_true(channel.save(rec, { data = data }))
        assert.equals(sha("f"), channel.accepted({ channel = "stable" }, ASSET, { data = data }).sha256)
        assert.is_nil(channel.accepted({ channel = "stable", download = false }, ASSET, { data = data }))
        assert.is_nil(channel.accepted({ channel = "stable" }, "lw-other", { data = data }))
        d.objects = {}
        assert.is_true(channel.save(rec, { data = data }))
        assert.is_nil(channel.accepted({ channel = "stable" }, ASSET, { data = data }))
        vim.fn.delete(data, "rf")
    end)

    it("checkhealth reports the last check without querying", function()
        local data = tmpdata()
        assert.is_nil(channel.describe(nil))
        assert.truthy(channel.describe({ channel = "stable" }, { data = data })[1]:find("not checked yet", 1, true))
        assert.truthy(channel.describe({ channel = "stable", download = false })[1]:find("no effect", 1, true))
        channel.save({ format = 1, channel = "stable", checked = os.time(), note = "the note" }, { data = data })
        assert.truthy(channel.describe({ channel = "stable" }, { data = data })[1]:find("the note", 1, true))
        vim.fn.delete(data, "rf")
    end)
end)

describe("binary.channel: the setting and the selection", function()
    it("validates the setting", function()
        assert.equals("stable", binsel.check_setting({ channel = "stable" }).channel)
        local s, w = binsel.check_setting({ channel = "beta" })
        assert.is_nil(s.channel)
        assert.truthy(w:find("binary.channel: expected", 1, true))
    end)

    it("an lw on PATH is never channel-resolved: the selection says why", function()
        local _, _, sel = binsel.resolve("/r", { setting = { channel = "unstable" }, getenv = function() return nil end,
            on_path = function() return "/usr/bin/lw" end, managed = function() return "/m/lw" end, probe = false })
        assert.equals("PATH", sel.source)
        assert.truthy(sel.channel_note:find("has no effect: lw on PATH is selected", 1, true), sel.channel_note)
        local _, _, sel2 = binsel.resolve("/r", { setting = { channel = "unstable", prefer = "managed" },
            getenv = function() return nil end, on_path = function() return "/usr/bin/lw" end,
            managed = function(o)
                assert.equals("unstable", o.setting.channel) -- the managed lw weighs the channel
                return "/m/lw"
            end, probe = false })
        assert.equals("managed", sel2.source)
        assert.is_nil(sel2.channel_note)
    end)
end)

describe("binary.channel: the observer's background check", function()
    local obs, data
    local fetched, queries, pruned
    local Q -- the pending query callback
    before_each(function()
        data = tmpdata()
        fetched, queries, pruned, Q = {}, {}, nil, nil
    end)
    after_each(function()
        if obs then obs:stop() end
        obs = nil
        vim.fn.delete(data, "rf")
    end)

    local pin = { sha256 = sha("1"), version = "0.1.44-beta.2", asset = ASSET }
    local function attach(extra)
        local o = {
            getenv = function(n) if n == "LOOMWORKS_RUNTIME" then return "daemon" end end,
            data = data, binary = { channel = "unstable" },
            -- Its relay waits (spawns nothing real, never answers).
            relay = function() return { close = function() end } end,
            inspect = function() return { kind = "starting", lock = { pid = 7 } } end,
            resolve = function() return "/m/lw", "managed", { path = "/m/lw", source = "managed", label = "plugin-managed lw", candidates = {} } end,
            pinned_wanted = function() return pin end,
            fetch = function(w, _, cb) fetched[#fetched + 1] = w; cb("/m/" .. w.sha256 .. "/lw") end,
            channel_query = function(p, ch, o2, cb) queries[#queries + 1] = { p, ch, o2 }; Q = cb end,
            prune = function(o2) pruned = o2 end,
        }
        for k, v in pairs(extra or {}) do o[k] = v end
        return observer.attach({ root = "/r" }, o)
    end

    it("makes the pinned lw present, queries, downloads an accepted release, records it and keeps both", function()
        obs = attach()
        assert.equals(1, #queries)
        assert.same(pin, fetched[1])
        assert.equals("/m/" .. pin.sha256 .. "/lw", queries[1][1])
        assert.equals("unstable", queries[1][2])
        Q(query_res("9.9.9-beta.1", sha("9")))
        assert.equals(2, #fetched)
        assert.equals(sha("9"), fetched[2].sha256)
        local rec = channel.load({ data = data })
        assert.equals("9.9.9-beta.1", rec.accepted.version)
        assert.truthy(obs.channel_note:find("lw v9.9.9-beta.1 from unstable is installed", 1, true), obs.channel_note)
        assert.truthy(obs:runtime_line():find("is installed", 1, true))
        assert.truthy(vim.tbl_contains(pruned.keep, sha("9")) and vim.tbl_contains(pruned.keep, pin.sha256),
            vim.inspect(pruned.keep))
        -- Prunes the same data dir its keep-list was built from (never the real stdpath).
        assert.equals(data, pruned.data)
        -- Not due again for a day; an explicit connect checks again.
        obs:start(false)
        assert.equals(1, #queries)
        obs:start(true)
        assert.equals(2, #queries)
    end)

    it("a probe finishing while a check is in flight keeps the check: no second query, its result is recorded", function()
        obs = attach({ run_probe = function(_, _, cb) cb({ ok = true }) end })
        assert.equals(1, #queries)
        obs:_probe("/other/lw")
        assert.is_nil(obs._probing)
        -- A watch tick while the check is still in flight starts no second query.
        obs:start(false)
        assert.equals(1, #queries)
        Q(query_res("9.9.9-beta.1", sha("9")))
        assert.equals("9.9.9-beta.1", channel.load({ data = data }).accepted.version)
        assert.truthy(obs.channel_note:find("is installed", 1, true), tostring(obs.channel_note))
    end)

    it("an explicit connect during a check re-runs it once that check ends; a plain tick does not", function()
        obs = attach()
        assert.equals(1, #queries)
        obs:start(true) -- in flight: remembered, not run
        assert.equals(1, #queries)
        Q(query_res("9.9.9-beta.1", sha("9")))
        assert.equals("9.9.9-beta.1", channel.load({ data = data }).accepted.version)
        assert.is_true(vim.wait(2000, function() return #queries == 2 end, 10))
        Q(query_res("9.9.9-beta.1", sha("9")))
        -- Done: neither a plain start nor a tick queries again before it is due.
        obs:start(false)
        vim.wait(100)
        assert.equals(2, #queries)
        -- A later explicit connect still checks again.
        obs:start(true)
        assert.equals(3, #queries)
    end)

    it("a check that ends with no explicit connect pending runs no second query", function()
        obs = attach()
        Q(query_res("9.9.9-beta.1", sha("9")))
        vim.wait(100)
        obs:start(false)
        assert.equals(1, #queries)
    end)

    it("a low-rate tick weighs it in a long session: the undecided retry, then the daily re-check", function()
        local now, decided = 1000000, false
        local managed_sel = { path = "/m/lw", source = "managed", label = "plugin-managed lw", candidates = {} }
        obs = attach({
            channel_tick_ms = 20,
            now = function() return now end,
            resolve = function()
                if decided then return "/m/lw", "managed", managed_sel end
                return "/p/lw", "path", { path = "/p/lw", source = "path", probe = "/p/lw", candidates = {} }
            end,
            run_probe = function() end, -- never answers here
        })
        assert.is_not_nil(obs._channel_timer)
        assert.equals(0, #queries)
        -- Decided, but the undecided retry (CHANNEL_RETRY_S) is not up yet.
        decided = true
        vim.wait(100)
        assert.equals(0, #queries)
        now = now + observer.CHANNEL_RETRY_S
        assert.is_true(vim.wait(2000, function() return #queries == 1 end, 10))
        Q(query_res("9.9.9-beta.1", sha("9")))
        -- Not due again until a day later.
        now = now + channel.INTERVAL_S - 10
        vim.wait(100)
        assert.equals(1, #queries)
        now = now + 20
        assert.is_true(vim.wait(2000, function() return #queries == 2 end, 10))
        Q(query_res("9.9.9-beta.1", sha("9")))
        -- Stopped: the timer is gone and nothing is weighed any more.
        local t = obs._channel_timer
        obs:stop()
        assert.is_nil(obs._channel_timer)
        assert.is_true(t:is_closing())
        now = now + 2 * channel.INTERVAL_S
        vim.wait(100)
        assert.equals(2, #queries)
        obs = nil
    end)

    it("a probe that decides the selection weighs the channel at once, not after the retry", function()
        local decided, P = false, nil
        local managed_sel = { path = "/m/lw", source = "managed", label = "plugin-managed lw", candidates = {} }
        obs = attach({
            resolve = function()
                if decided then return "/m/lw", "managed", managed_sel end
                return "/p/lw", "path", { path = "/p/lw", source = "path", probe = "/p/lw", candidates = {} }
            end,
            run_probe = function(_, _, cb) P = cb end,
        })
        assert.equals(0, #queries)
        assert.is_not_nil(P)
        decided = true
        P({ ok = true })
        assert.equals(1, #queries)
    end)

    it("a download that ends weighs the channel again", function()
        local decided, D = false, nil
        local want = { sha256 = sha("7"), version = "0.1.44-beta.2", asset = ASSET }
        local managed_sel = { path = "/m/lw", source = "managed", label = "plugin-managed lw", candidates = {} }
        obs = attach({
            resolve = function()
                if decided then return "/m/lw", "managed", managed_sel end
                return nil, nil, { download = want, candidates = {} }
            end,
            fetch = function(w, _, cb)
                fetched[#fetched + 1] = w
                if w == want then D = cb else cb("/m/" .. w.sha256 .. "/lw") end
            end,
        })
        assert.equals(0, #queries)
        assert.is_not_nil(D)
        decided = true
        D("/m/" .. want.sha256 .. "/lw")
        assert.equals(1, #queries)
    end)

    it("an lw without the query command keeps the pin: one note, no download, not retried until due", function()
        obs = attach()
        Q({ code = 2, stdout = "", stderr = "lw: unknown command 'release' — run `lw help`" })
        assert.equals(1, #fetched)
        assert.truthy(obs.channel_note:find("has no `lw release query`", 1, true), obs.channel_note)
        assert.is_nil(channel.load({ data = data }).accepted)
        obs:start(false)
        assert.equals(1, #queries)
    end)

    it("a failed download of the accepted release records nothing accepted", function()
        obs = attach({ fetch = function(w, _, cb)
            fetched[#fetched + 1] = w
            if w.sha256 == pin.sha256 then return cb("/m/pin/lw") end
            cb(nil, "HTTP 404")
        end })
        Q(query_res("9.9.9", sha("9")))
        assert.is_nil(channel.load({ data = data }).accepted)
        assert.truthy(obs.channel_note:find("could not install lw v9.9.9 from unstable: HTTP 404", 1, true), obs.channel_note)
    end)

    it("does nothing when an lw on PATH is selected, and says why", function()
        obs = attach({ resolve = function(_, o)
            return binsel.resolve("/r", { setting = o.setting, getenv = function() return nil end,
                on_path = function() return "/usr/bin/lw" end, managed = function() return "/m/lw" end, probe = false })
        end })
        assert.equals(0, #queries)
        assert.truthy(obs.channel_note:find("has no effect", 1, true), tostring(obs.channel_note))
    end)

    it("does nothing with the channel unset; a late answer after a stop is ignored", function()
        obs = attach({ binary = {} })
        assert.equals(0, #queries)
        obs:stop()
        obs = attach()
        obs:stop()
        Q(query_res("9.9.9"))
        assert.equals(1, #fetched)
        assert.is_nil(channel.load({ data = data }))
        obs = nil
    end)
end)
