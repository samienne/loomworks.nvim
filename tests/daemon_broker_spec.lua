-- Runtime broker: the §5.2 resolution precedence chain (decision-only).

local broker = require("loomworks.daemon.broker")

-- A probe bundle that resolves nothing, so each test opts into exactly the rung
-- it exercises. Precedence is asserted by adding higher rungs on top.
local function probes(over)
    local base = {
        getenv = function() return nil end,
        pin_read = function() return nil end,
        which = function() return nil end,
        data_runtime = function() return nil end,
    }
    for k, v in pairs(over or {}) do base[k] = v end
    return base
end

describe("daemon.broker resolve", function()
    it("falls through to bundled-dev (in-process) when nothing resolves", function()
        local r = broker.resolve("/ws", probes())
        assert.equals(broker.KIND.bundled_dev, r.kind)
        assert.is_true(r.in_process)
    end)

    it("honors LOOMWORKS_LW above everything", function()
        local r = broker.resolve("/ws", probes({
            getenv = function(n) return n == "LOOMWORKS_LW" and "/opt/lw" or nil end,
            pin_read = function() return { version = "9.9.9" } end,
            which = function() return "/usr/bin/lw" end,
        }))
        assert.equals(broker.KIND.env_override, r.kind)
        assert.equals("/opt/lw", r.path)
        assert.is_false(r.in_process)
    end)

    it("uses the repo pin above PATH and data-cache", function()
        local r = broker.resolve("/ws", probes({
            pin_read = function() return { version = "1.2.3" } end,
            which = function() return "/usr/bin/lw" end,
            data_runtime = function() return "/data/lw" end,
        }))
        assert.equals(broker.KIND.pin, r.kind)
        assert.equals("1.2.3", r.version)
    end)

    it("uses system lw on PATH above the data cache", function()
        local r = broker.resolve("/ws", probes({
            which = function(exe) return exe == "lw" and "/usr/bin/lw" or nil end,
            data_runtime = function() return "/data/lw" end,
        }))
        assert.equals(broker.KIND.system, r.kind)
        assert.equals("/usr/bin/lw", r.path)
        assert.is_true(r.needs_protocol_probe)
    end)

    it("uses a provisioned data-cache runtime when present", function()
        local r = broker.resolve("/ws", probes({
            data_runtime = function() return "/data/loomworks/lw-1.0" end,
        }))
        assert.equals(broker.KIND.data_cache, r.kind)
        assert.equals("/data/loomworks/lw-1.0", r.path)
    end)

    it("accepts a system lw whose probed protocol is in range", function()
        local proto = require("loomworks.daemon.protocol")
        local r = broker.resolve("/ws", probes({
            which = function() return "/usr/bin/lw" end,
            probe = function() return { version = proto.VERSION, min = proto.MIN_SUPPORTED } end,
        }))
        assert.equals(broker.KIND.system, r.kind)
        assert.equals(proto.VERSION, r.protocol_version)
        assert.is_nil(r.needs_protocol_probe)
    end)

    it("falls through a system lw whose protocol is out of range", function()
        local proto = require("loomworks.daemon.protocol")
        local r = broker.resolve("/ws", probes({
            which = function() return "/usr/bin/lw" end,
            probe = function() return { version = proto.VERSION + 99, min = proto.VERSION + 99 } end,
            data_runtime = function() return "/data/lw" end,
        }))
        -- Incompatible system host rejected; next rung wins.
        assert.equals(broker.KIND.data_cache, r.kind)
    end)

    it("leaves the compat owed when a system lw cannot be probed", function()
        local r = broker.resolve("/ws", probes({
            which = function() return "/usr/bin/lw" end,
            probe = function() return nil end, -- probe ran, told us nothing
        }))
        assert.equals(broker.KIND.system, r.kind)
        assert.is_true(r.needs_protocol_probe)
    end)

    it("probe parses `protocol N (min M)` output", function()
        local info = broker.probe("/usr/bin/lw", {
            run = function() return { code = 0, stdout = "protocol 3 (min 2)\n" } end,
        })
        assert.equals(3, info.version)
        assert.equals(2, info.min)
    end)

    it("probe reports failure on a bad exit or unparseable output", function()
        assert.is_nil(broker.probe("/x", { run = function() return { code = 1, stdout = "" } end }))
        assert.is_nil(broker.probe("/x", { run = function() return { code = 0, stdout = "nope" } end }))
    end)

    it("never resolves to a fetch (never auto-installs)", function()
        -- With nothing present the chain must NOT surface a fetch action; it
        -- falls straight through to the in-process fallback.
        local r = broker.resolve("/ws", probes())
        assert.are_not.equal("fetch", r.kind)
        assert.is_true(r.in_process)
    end)
end)
