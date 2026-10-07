-- The editor's pre-launch probe of a search-path or explicit lw (spec §19.16
-- "Pre-launch probe", step 5h.5): `lw version --json` weighed with the plugin
-- pin's check — compatible / incompatible (no transport overlap, schemas ours
-- cannot use, no root interface) / unknown (no descriptor, a timeout); a
-- missing feature interface only degrades; the verdict cached per binary
-- (realpath, size, mtime); the selection falls through from an incompatible
-- lw on PATH to the managed lw, never from an explicit one.

local probe = require("loomworks.provision.probe")
local needs = require("loomworks.provision.needs")
local binsel = require("loomworks.provision.select")
local version = require("loomworks.daemon.version")
local observer = require("loomworks.daemon.observer")
local uv = vim.uv or vim.loop

--- A descriptor of this build (compatible by construction).
local function descriptor()
    return require("loomworks.daemon.descriptor").describe()
end

--- `d` with the interface `want` removed from its objects.
local function without(d, want)
    for _, o in ipairs(d.objects or {}) do
        if o.path == want.object or o.object == want.object then
            local keep = {}
            for _, i in ipairs(o.interfaces or {}) do
                if i.name ~= want.iface then keep[#keep + 1] = i end
            end
            o.interfaces = keep
        end
    end
    return d
end

local function ok_res(d) return { code = 0, stdout = vim.json.encode(d), stderr = "" } end

describe("probe verdicts (§19.16 Pre-launch probe)", function()
    it("a descriptor of this build is compatible", function()
        local v = probe.classify(ok_res(descriptor()))
        assert.equals("compatible", v.verdict, probe.describe(v))
        assert.same({}, v.problems); assert.same({}, v.degraded)
        assert.equals(version.identity(), v.version)
    end)

    it("no transport overlap is incompatible", function()
        local d = descriptor()
        d.transport = { min = version.PROTOCOL + 5, max = version.PROTOCOL + 6 }
        local v = probe.classify(ok_res(d))
        assert.equals("incompatible", v.verdict)
        assert.truthy(v.problems[1]:find("does not overlap", 1, true), v.problems[1])
    end)

    it("newer schemas are incompatible", function()
        local d = descriptor()
        local s = version.schemas()
        d.schemas = { user = s.user + 1, cache = s.cache }
        local v = probe.classify(ok_res(d))
        assert.equals("incompatible", v.verdict)
        assert.truthy(v.problems[1]:find("schemas", 1, true), v.problems[1])
    end)

    it("a missing root interface is incompatible, a missing feature interface only degrades", function()
        local d = without(descriptor(), observer.ROOT)
        local p = needs.problems(d)
        assert.equals(1, #p.fatal, vim.inspect(p))
        local v = probe.classify(ok_res(d))
        assert.equals("incompatible", v.verdict, probe.describe(v))

        local feature = observer.FEATURES[1]
        d = without(descriptor(), feature)
        v = probe.classify(ok_res(d))
        assert.equals("compatible", v.verdict, probe.describe(v))
        assert.equals(1, #v.degraded)
        assert.truthy(v.degraded[1]:find(feature.iface, 1, true), v.degraded[1])
        assert.truthy(probe.describe(v):find("degraded", 1, true))
        -- The pin gate still counts every problem.
        local ok, problems = needs.check(d)
        assert.is_false(ok); assert.equals(1, #problems)
    end)

    it("no descriptor, a failed command or a timeout is unknown", function()
        assert.equals("unknown", probe.classify({ code = 2, stdout = "", stderr = "lw: unknown option --json\n" }).verdict)
        assert.equals("unknown", probe.classify({ code = 0, stdout = "lw 0.1.20\n" }).verdict)
        assert.equals("unknown", probe.classify({ code = 0, stdout = vim.json.encode({ hello = 1 }) }).verdict)
        local v = probe.classify({ code = 124, timed_out = true })
        assert.equals("unknown", v.verdict)
        assert.truthy(v.problems[1]:find("did not answer", 1, true))
        assert.same({ false, { "no descriptor" } }, { needs.check(nil) })
    end)
end)

describe("probe.run (async, bounded, cached per binary)", function()
    local dir, bin
    before_each(function()
        probe.reset()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        bin = dir .. "/lw-fake"
        vim.fn.writefile({ "fake" }, bin)
    end)
    after_each(function()
        probe.reset()
        vim.fn.delete(dir, "rf")
    end)

    --- An argv that runs a Lua script under nvim -l (a stand-in for lw).
    local function script(lines)
        local f = dir .. "/probe_" .. tostring(uv.hrtime()) .. ".lua"
        vim.fn.writefile(lines, f)
        return { vim.v.progpath, "--clean", "-l", f }
    end

    local function wait_run(path, opts)
        local got
        probe.run(path, opts, function(v) got = v end)
        assert.is_true(vim.wait(20000, function() return got ~= nil end, 20))
        return got
    end

    it("runs the binary in a neutral cwd, decodes its descriptor and caches the verdict", function()
        local json = dir .. "/d.json"
        vim.fn.writefile({ vim.json.encode(descriptor()) }, json)
        local cwdfile = dir .. "/cwd.txt"
        local argv = script({
            "io.write(io.open(" .. string.format("%q", json) .. "):read('a'))",
            "local f = io.open(" .. string.format("%q", cwdfile) .. ", 'w') f:write(vim.uv.cwd()) f:close()",
        })
        assert.is_nil(probe.cached(bin))
        local v = wait_run(bin, { argv = argv, cwd = dir, timeout_ms = 15000 })
        assert.equals("compatible", v.verdict, probe.describe(v))
        assert.equals(vim.fs.normalize(uv.fs_realpath(dir)), vim.fs.normalize(uv.fs_realpath(vim.fn.readfile(cwdfile)[1])))
        assert.equals(v, probe.cached(bin))
        -- Cached: a second run does not start a process.
        local v2 = wait_run(bin, { argv = { "no-such-command-at-all" } })
        assert.equals(v, v2)
    end)

    it("a changed binary (size/mtime) is probed again", function()
        local v = wait_run(bin, { argv = script({ "io.write('not json')" }) })
        assert.equals("unknown", v.verdict)
        vim.fn.writefile({ "fake, but longer now" }, bin)
        assert.is_nil(probe.cached(bin))
    end)

    it("is bounded: a binary that does not answer is unknown", function()
        local v = wait_run(bin, { argv = script({ "vim.uv.sleep(10000)" }), timeout_ms = 300 })
        assert.equals("unknown", v.verdict)
        assert.truthy(v.problems[1]:find("did not answer", 1, true), v.problems[1])
    end)

    it("concurrent probes of one binary share one process", function()
        local count = dir .. "/count.txt"
        local argv = script({ "local f = io.open(" .. string.format("%q", count) .. ", 'a') f:write('x') f:close()",
            "io.write('{}')" })
        local a, b
        probe.run(bin, { argv = argv, timeout_ms = 15000 }, function(v) a = v end)
        probe.run(bin, { argv = argv, timeout_ms = 15000 }, function(v) b = v end)
        assert.is_true(vim.wait(20000, function() return a and b end, 20))
        assert.equals(a, b)
        assert.equals("x", vim.fn.readfile(count)[1])
    end)

    it("an unreadable binary is unknown without running anything", function()
        assert.equals("unknown", probe.cached(dir .. "/missing").verdict)
        assert.equals("unknown", wait_run(dir .. "/missing", { argv = { "no-such-command-at-all" } }).verdict)
    end)
end)

describe("selection over probe verdicts (§19.16)", function()
    local incompatible = { verdict = "incompatible", problems = { "transport 1..2 does not overlap ours 10..11" }, degraded = {} }
    local unknown = { verdict = "unknown", problems = { "timeout" }, degraded = {} }
    local compatible = { verdict = "compatible", problems = {}, degraded = {} }

    local function run(o)
        return binsel.resolve("/r", {
            getenv = function(n) return (o.env or {})[n] end,
            setting = o.setting, win = false, cwd = "/cwd",
            exists = function() return true end,
            on_path = function() if o.path then return o.path end return nil, "no lw on the search path" end,
            managed = function() if o.managed then return o.managed end return nil, "not installed" end,
            probe = o.verdicts and function(p) return o.verdicts[p] end or o.probe,
        })
    end

    local function verdicts(sel)
        local out = {}
        for _, c in ipairs(sel.candidates) do out[#out + 1] = c.source .. "=" .. c.verdict end
        return table.concat(out, " ")
    end

    it("an incompatible lw on PATH falls through to the managed lw, with a note", function()
        local bin, src, sel = run({ path = "/p/lw", managed = "/m/lw", verdicts = { ["/p/lw"] = incompatible } })
        assert.equals("/m/lw", bin); assert.equals("managed", src)
        assert.equals("LOOMWORKS_LW=absent setting=absent PATH=refused managed=chosen", verdicts(sel))
        assert.truthy(sel.candidates[3].reason:find("too old/incompatible: transport", 1, true))
        assert.truthy(sel.probe_note:find("lw on PATH (/p/lw) is too old/incompatible", 1, true), sel.probe_note)
        assert.is_nil(sel.probe)
    end)

    it("with no managed lw either, nothing is chosen and the note says why", function()
        local bin, _, sel = run({ path = "/p/lw", verdicts = { ["/p/lw"] = incompatible } })
        assert.is_nil(bin)
        assert.truthy(binsel.none_note(sel):find("too old/incompatible", 1, true), binsel.none_note(sel))
    end)

    it("compatible or unknown is used; no verdict yet is chosen and named for probing", function()
        local bin, _, sel = run({ path = "/p/lw", managed = "/m/lw", verdicts = { ["/p/lw"] = compatible } })
        assert.equals("/p/lw", bin); assert.is_nil(sel.probe); assert.is_nil(sel.probe_note)
        bin, _, sel = run({ path = "/p/lw", managed = "/m/lw", verdicts = { ["/p/lw"] = unknown } })
        assert.equals("/p/lw", bin); assert.is_nil(sel.probe)
        assert.truthy(binsel.describe(sel):find("probe: unknown: timeout", 1, true), binsel.describe(sel))
        bin, _, sel = run({ path = "/p/lw", managed = "/m/lw", verdicts = {} })
        assert.equals("/p/lw", bin); assert.equals("/p/lw", sel.probe)
        assert.truthy(binsel.describe(sel):find("not probed yet", 1, true))
        bin, _, sel = run({ path = "/p/lw", probe = false })
        assert.equals("/p/lw", bin); assert.is_nil(sel.probe)
    end)

    it("an explicit lw is probed but never replaced: an incompatible verdict is only noted", function()
        local bin, src, sel = run({ env = { LOOMWORKS_LW = "/e/lw" }, path = "/p/lw", managed = "/m/lw",
            verdicts = { ["/e/lw"] = incompatible } })
        assert.equals("/e/lw", bin); assert.equals("LOOMWORKS_LW", src)
        assert.truthy(sel.probe_note:find("LOOMWORKS_LW /e/lw is incompatible", 1, true), sel.probe_note)
        assert.truthy(sel.probe_note:find("used as named", 1, true))
        bin, src, sel = run({ setting = { path = "/s/lw" }, verdicts = {} })
        assert.equals("/s/lw", bin); assert.equals("setting", src); assert.equals("/s/lw", sel.probe)
    end)

    it("the managed lw is never probed", function()
        local asked = {}
        local bin, _, sel = run({ managed = "/m/lw", setting = { prefer = "managed" },
            probe = function(p) asked[#asked + 1] = p end })
        assert.equals("/m/lw", bin); assert.same({}, asked); assert.is_nil(sel.probe)
    end)
end)
