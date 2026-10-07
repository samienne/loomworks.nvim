-- The host binary the editor launches the workspace daemon from (spec §19.16
-- "Host binary", step 5h.1): explicit (LOOMWORKS_LW, then `binary.path`) >
-- lw on PATH > the plugin-managed lw, `binary.prefer = "managed"` swapping
-- the last two; an explicit value naming no file stops the search; the
-- managed slot only looks under the editor's data directory; checkhealth
-- lists every source.

local binsel = require("loomworks.provision.select")
local managed = require("loomworks.provision.managed")

local function env(t) return function(n) return t[n] end end
local function files(set) return function(p) return set[p] == true end end

--- resolve with every seam injected.
local function run(o)
    return binsel.resolve("/r", {
        getenv = env(o.env or {}),
        setting = o.setting,
        exists = files(o.files or {}),
        on_path = function() if o.path then return o.path end return nil, "no lw on the search path" end,
        managed = function() if o.managed then return o.managed end return nil, managed.NOT_YET end,
        is_dir = function(d) return o.dirs and o.dirs[d] or false end,
        plugin_lua = function() return o.plugin_lua end,
    })
end

local function verdicts(sel)
    local out = {}
    for _, c in ipairs(sel.candidates) do out[#out + 1] = c.source .. "=" .. c.verdict end
    return table.concat(out, " ")
end

describe("host binary order (§19.16)", function()
    it("LOOMWORKS_LW wins over the setting, PATH and the managed lw", function()
        local bin, src, sel = run({ env = { LOOMWORKS_LW = "/e/lw" }, setting = { path = "/s/lw" },
            files = { ["/e/lw"] = true, ["/s/lw"] = true }, path = "/p/lw", managed = "/m/lw" })
        assert.equals("/e/lw", bin); assert.equals("LOOMWORKS_LW", src)
        assert.equals("LOOMWORKS_LW=chosen setting=not tried PATH=not tried managed=not tried", verdicts(sel))
    end)

    it("the binary.path setting comes next", function()
        local bin, src = run({ setting = { path = "/s/lw" }, files = { ["/s/lw"] = true }, path = "/p/lw" })
        assert.equals("/s/lw", bin); assert.equals("setting", src)
    end)

    it("an explicit value naming no file is a note and stops the search", function()
        local bin, src, sel = run({ env = { LOOMWORKS_LW = "/gone/lw" }, path = "/p/lw", managed = "/m/lw" })
        assert.is_nil(bin); assert.is_nil(src)
        assert.equals("LOOMWORKS_LW=refused setting=not tried PATH=not tried managed=not tried", verdicts(sel))
        assert.truthy(sel.note:find("LOOMWORKS_LW names /gone/lw, which is not a file", 1, true), sel.note)
        assert.equals(sel.note, binsel.none_note(sel))
        bin, src, sel = run({ setting = { path = "/gone/lw" }, path = "/p/lw" })
        assert.is_nil(bin)
        assert.truthy(sel.note:find("binary.path setting names /gone/lw", 1, true), sel.note)
    end)

    it("then lw on PATH, then the plugin-managed lw", function()
        local bin, src, sel = run({ path = "/p/lw", managed = "/m/lw" })
        assert.equals("/p/lw", bin); assert.equals("PATH", src)
        assert.equals("LOOMWORKS_LW=absent setting=absent PATH=chosen managed=not tried", verdicts(sel))
        bin, src, sel = run({ managed = "/m/lw" })
        assert.equals("/m/lw", bin); assert.equals("managed", src)
        assert.equals("/m/lw (plugin-managed lw)", binsel.describe(sel))
    end)

    it("binary.prefer = managed puts the plugin-managed lw before PATH", function()
        local bin, src, sel = run({ setting = { prefer = "managed" }, path = "/p/lw", managed = "/m/lw" })
        assert.equals("/m/lw", bin); assert.equals("managed", src)
        assert.equals("LOOMWORKS_LW=absent setting=absent managed=chosen PATH=not tried", verdicts(sel))
        bin, src = run({ setting = { prefer = "managed" }, path = "/p/lw" })
        assert.equals("/p/lw", bin); assert.equals("PATH", src)
    end)

    it("with none, the note names every source and why", function()
        local bin, _, sel = run({})
        assert.is_nil(bin)
        assert.equals("no lw host binary (LOOMWORKS_LW: not set; binary.path setting: not set; "
            .. "lw on PATH: no lw on the search path; plugin-managed lw: " .. managed.NOT_YET
            .. ") — running in-process", sel.note)
        assert.equals(binsel.NONE_NOTE, binsel.none_note(nil))
    end)

    it("binary.source (development only) adds LOOMWORKS_LUA to a chosen binary, never chooses one", function()
        local bin, _, sel = run({ setting = { source = "/src/lua" }, path = "/p/lw", dirs = { ["/src/lua"] = true } })
        assert.equals("/p/lw", bin)
        assert.same({ LOOMWORKS_LUA = "/src/lua" }, sel.env)
        assert.truthy(binsel.describe(sel):find("with the Lua source /src/lua", 1, true))
        _, _, sel = run({ setting = { source = true }, path = "/p/lw", plugin_lua = "/plug/lua",
            dirs = { ["/plug/lua"] = true } })
        assert.same({ LOOMWORKS_LUA = "/plug/lua" }, sel.env)
        _, _, sel = run({ setting = { source = "/nope" }, path = "/p/lw" })
        assert.is_nil(sel.env)
        assert.truthy(sel.warning:find("is not a directory", 1, true), sel.warning)
        bin, _, sel = run({ setting = { source = "/src/lua" }, dirs = { ["/src/lua"] = true } })
        assert.is_nil(bin); assert.is_nil(sel.env)
    end)

    it("checks the setup option", function()
        assert.same({}, (binsel.check_setting(nil)))
        local s, w = binsel.check_setting({ path = "/x", prefer = "managed", source = false })
        assert.same({ path = "/x", prefer = "managed" }, s); assert.is_nil(w)
        s, w = binsel.check_setting({ path = 3, prefer = "fast", source = 7 })
        assert.same({}, s)
        assert.truthy(w:find("binary.path", 1, true) and w:find("binary.prefer", 1, true)
            and w:find("binary.source", 1, true), w)
        s, w = binsel.check_setting("lw")
        assert.same({}, s); assert.truthy(w)
    end)
end)

describe("lw on PATH (§19.16)", function()
    it("is the resolved binary; on Windows only an .exe", function()
        local p = binsel.on_path({ exepath = function() return "C:\\bin\\lw.EXE" end,
            realpath = function() return "C:\\opt\\lw.exe" end, win = true })
        assert.equals("C:/opt/lw.exe", p)
        local none, why = binsel.on_path({ exepath = function() return "C:\\bin\\lw.cmd" end,
            realpath = function(x) return x end, win = true })
        assert.is_nil(none); assert.truthy(why:find("not an .exe", 1, true))
        assert.equals("/usr/bin/lw", binsel.on_path({ exepath = function() return "/usr/bin/lw" end,
            realpath = function() return nil end, win = false }))
        none, why = binsel.on_path({ exepath = function() return "" end })
        assert.is_nil(none); assert.equals("no lw on the search path", why)
    end)
end)

describe("the plugin-managed lw (§19.16)", function()
    local sha = string.rep("ab", 32)

    it("lives content-addressed under the editor's data directory", function()
        assert.equals("/d/loomworks/lw/" .. sha .. "/lw", managed.path(sha, { data = "/d", win = false }))
        assert.equals("C:/d/loomworks/lw/" .. sha .. "/lw.exe",
            managed.path(sha:upper(), { data = "C:\\d\\", win = true }))
        assert.is_nil(managed.path("../../x", { data = "/d" }))
        assert.is_nil(managed.path(string.rep("a", 63), { data = "/d" }))
        assert.is_nil(managed.path(string.rep("g", 64), { data = "/d" }))
    end)

    it("is only looked for: present when the wanted binary exists, else why", function()
        local p = "/d/loomworks/lw/" .. sha .. "/lw"
        local got, why = managed.find({ data = "/d", win = false, wanted = function() return sha end,
            exists = function(x) return x == p end })
        assert.equals(p, got); assert.is_nil(why)
        got, why = managed.find({ data = "/d", win = false, wanted = function() return sha end,
            exists = function() return false end })
        assert.is_nil(got); assert.truthy(why:find("not installed", 1, true))
        got, why = managed.find({ data = "/d" })
        assert.is_nil(got); assert.equals(managed.NOT_YET, why)
        got, why = managed.find({ data = "/d", wanted = function() return "zz" end })
        assert.is_nil(got); assert.truthy(why:find("invalid hash", 1, true))
    end)

    it("finds a real file on disk", function()
        local data = vim.fn.tempname()
        local p = managed.path(sha, { data = data })
        vim.fn.mkdir(vim.fs.dirname(p), "p")
        local f = assert(io.open(p, "w")); f:write("x"); f:close()
        assert.equals(p, (managed.find({ data = data, wanted = function() return sha end })))
        vim.fn.delete(data, "rf")
    end)
end)

describe(":checkhealth loomworks", function()
    local function capture()
        local out = {}
        local h = {}
        for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
            h[k] = function(msg) out[#out + 1] = k .. ": " .. msg end
        end
        return h, out
    end

    it("names the chosen binary and every source", function()
        local h, out = capture()
        local _, _, sel = run({ path = "/p/lw" })
        require("loomworks.health").check(h, {
            runtime_mode = function() return "daemon", "setup" end,
            daemon_runtime_line = function() return "daemon (setup) — observing daemon pid 7" end,
            host_binary_selection = function() return sel end,
        })
        local text = table.concat(out, "\n")
        assert.truthy(text:find("info: runtime mode: daemon (setup)", 1, true), text)
        assert.truthy(text:find("ok: would launch the workspace daemon from /p/lw (lw on PATH)", 1, true), text)
        assert.truthy(text:find("info: plugin-managed lw: not tried", 1, true), text)
    end)

    it("warns when daemon mode has no binary, informs otherwise", function()
        local _, _, sel = run({})
        local h, out = capture()
        local lw = { runtime_mode = function() return "daemon", "env" end,
            daemon_runtime_line = function() return nil end,
            host_binary_selection = function() return sel end }
        require("loomworks.health").check(h, lw)
        assert.truthy(table.concat(out, "\n"):find("warn: no lw host binary (", 1, true))
        h, out = capture()
        lw.runtime_mode = function() return "in-process", "default" end
        require("loomworks.health").check(h, lw)
        local text = table.concat(out, "\n")
        assert.is_nil(text:find("warn:", 1, true), text)
        assert.truthy(text:find("only used in daemon mode", 1, true), text)
    end)
end)
